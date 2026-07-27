import AppKit

/// 区域框选：在每块屏幕上盖一层遮罩，让用户拖出一个矩形。
///
/// 交互：
/// - 拖拽 → 自由矩形（限制在起始那块屏幕内）
/// - 按住 `⌥` 单击 → 直接选中指针下的整个窗口
/// - `⎋` 或右键 → 取消
final class RegionSelectionController {
    static let shared = RegionSelectionController()

    struct Result {
        /// AppKit 全局坐标（左下原点，逻辑点）
        let screenRect: CGRect
        let screen: NSScreen
        let displayID: CGDirectDisplayID
        /// 若选区落在某个窗口内，则给出该窗口信息，捕获时优先用窗口流（可跟随移动、被遮挡也能拍）
        let hitWindowID: CGWindowID?
        /// 命中窗口在「左上原点全局坐标」下的 frame（与 SCWindow.frame 同坐标系）
        let hitWindowFrameTopLeft: CGRect?
        let hitWindowOwnerPID: pid_t?
    }

    private var overlays: [RegionOverlayWindow] = []
    private var completion: ((Result?) -> Void)?
    private(set) var isActive = false

    private init() {}

    // MARK: - 入口

    func begin(completion: @escaping (Result?) -> Void) {
        guard !isActive else { return }
        guard !NSScreen.screens.isEmpty else {
            completion(nil)
            return
        }
        isActive = true
        self.completion = completion

        for screen in NSScreen.screens {
            let overlay = RegionOverlayWindow(screen: screen)
            overlay.onFinish = { [weak self] rect, optionSnapped in
                self?.finish(rect: rect, screen: screen, snapWindow: optionSnapped)
            }
            overlay.onCancel = { [weak self] in self?.finish(rect: nil, screen: screen, snapWindow: false) }
            overlay.orderFrontRegardless()
            overlays.append(overlay)
        }
        NSApp.activate(ignoringOtherApps: true)
        overlays.first?.makeKey()
        Log.debug("进入区域框选，屏幕数 \(overlays.count)")
    }

    func cancel() { finish(rect: nil, screen: nil, snapWindow: false) }

    // MARK: - 结束

    private func finish(rect: CGRect?, screen: NSScreen?, snapWindow: Bool) {
        guard isActive else { return }
        isActive = false
        for overlay in overlays { overlay.orderOut(nil) }
        overlays.removeAll()

        let cb = completion
        completion = nil

        guard var rect, let screen else {
            cb?(nil)
            return
        }
        var targetScreen = screen

        // 命中测试：找最前面那个包含选区中心的普通窗口
        let hit = Self.frontmostWindow(containing: CGPoint(x: rect.midX, y: rect.midY))

        // ⌥ 吸附：直接用整个窗口的范围（左上原点 → AppKit 左下原点）
        if snapWindow, let hit {
            rect = CGRect(x: hit.frameTopLeft.minX,
                          y: Geo.primaryScreenMaxY - hit.frameTopLeft.maxY,
                          width: hit.frameTopLeft.width,
                          height: hit.frameTopLeft.height)
            let center = CGPoint(x: rect.midX, y: rect.midY)
            if let s = NSScreen.screens.first(where: { $0.frame.contains(center) }) {
                targetScreen = s
            }
        }

        rect = rect.intersection(targetScreen.frame).integral
        guard rect.width >= 40, rect.height >= 40 else {
            Log.debug("选区过小，已取消")
            cb?(nil)
            return
        }

        let displayID = Self.displayID(of: targetScreen)
        cb?(Result(
            screenRect: rect,
            screen: targetScreen,
            displayID: displayID,
            hitWindowID: hit?.windowID,
            hitWindowFrameTopLeft: hit?.frameTopLeft,
            hitWindowOwnerPID: hit?.ownerPID
        ))
    }

    // MARK: - 工具

    static func displayID(of screen: NSScreen) -> CGDirectDisplayID {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        return (screen.deviceDescription[key] as? NSNumber)?.uint32Value ?? CGMainDisplayID()
    }

    struct HitWindow {
        let windowID: CGWindowID
        /// 左上原点全局坐标（CGWindowList / SCWindow 使用的坐标系）
        let frameTopLeft: CGRect
        let ownerPID: pid_t
    }

    /// 用 CGWindowList 由前到后找包含指定点（AppKit 全局坐标）的窗口，跳过自身 App 与非普通层窗口。
    static func frontmostWindow(containing point: CGPoint) -> HitWindow? {
        let flipped = CGPoint(x: point.x, y: Geo.primaryScreenMaxY - point.y)
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                   kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        for info in list {
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t, pid != ownPID,
                  let idNum = info[kCGWindowNumber as String] as? UInt32,
                  let boundsDict = info[kCGWindowBounds as String] as? [String: CGFloat],
                  let rect = CGRect(dictionaryRepresentation: boundsDict as CFDictionary)
            else { continue }
            if rect.contains(flipped) {
                return HitWindow(windowID: CGWindowID(idNum), frameTopLeft: rect, ownerPID: pid)
            }
        }
        return nil
    }
}

// MARK: - 遮罩窗口

/// 单块屏幕上的框选遮罩。
private final class RegionOverlayWindow: NSWindow {
    var onFinish: ((CGRect, Bool) -> Void)?
    var onCancel: (() -> Void)?

    private let selectionView = RegionSelectionView()

    init(screen: NSScreen) {
        // 只能调用指定初始化器（带 screen: 的是便利初始化器），因此先用全局坐标建窗再定位
        super.init(contentRect: screen.frame, styleMask: [.borderless],
                   backing: .buffered, defer: false)
        setFrame(screen.frame, display: false)
        level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        ignoresMouseEvents = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        sharingType = .none
        contentView = selectionView
        selectionView.frame = CGRect(origin: .zero, size: screen.frame.size)
        selectionView.onFinish = { [weak self] rect, snap in
            guard let self else { return }
            // 视图坐标 → 全局坐标
            let global = CGRect(x: rect.minX + screen.frame.minX,
                               y: rect.minY + screen.frame.minY,
                               width: rect.width, height: rect.height)
            self.onFinish?(global, snap)
        }
        selectionView.onCancel = { [weak self] in self?.onCancel?() }
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// 遮罩内容：暗化背景 + 高亮选区 + 尺寸标签。
private final class RegionSelectionView: NSView {
    var onFinish: ((CGRect, Bool) -> Void)?
    var onCancel: (() -> Void)?

    private var origin: CGPoint?
    private var current: CGPoint?
    private var optionHeld = false

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    private var selectionRect: CGRect? {
        guard let origin, let current else { return nil }
        return CGRect(x: min(origin.x, current.x), y: min(origin.y, current.y),
                      width: abs(current.x - origin.x), height: abs(current.y - origin.y))
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.35).setFill()
        bounds.fill()

        if let rect = selectionRect, rect.width > 1, rect.height > 1 {
            // 挖空选区
            NSColor.clear.setFill()
            rect.fill(using: .copy)
            NSColor.controlAccentColor.setStroke()
            let path = NSBezierPath(rect: rect)
            path.lineWidth = 1.5
            path.stroke()
            drawSizeLabel(for: rect)
        } else {
            drawHint()
        }
    }

    private func drawSizeLabel(for rect: CGRect) {
        let text = "\(Int(rect.width)) × \(Int(rect.height))"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let size = (text as NSString).size(withAttributes: attrs)
        let padding: CGFloat = 5
        var box = CGRect(x: rect.minX, y: rect.maxY + 6,
                         width: size.width + padding * 2, height: size.height + padding)
        if box.maxY > bounds.maxY { box.origin.y = rect.minY - box.height - 6 }
        NSColor.black.withAlphaComponent(0.75).setFill()
        NSBezierPath(roundedRect: box, xRadius: 4, yRadius: 4).fill()
        (text as NSString).draw(at: NSPoint(x: box.minX + padding, y: box.minY + padding / 2),
                                withAttributes: attrs)
    }

    private func drawHint() {
        let text = L.t("拖拽选择区域　·　⌥ 单击选中整个窗口　·　⎋ 取消",
                       "Drag to select　·　⌥-click to grab a whole window　·　⎋ to cancel")
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.9),
        ]
        let size = (text as NSString).size(withAttributes: attrs)
        let box = CGRect(x: (bounds.width - size.width) / 2 - 12,
                         y: bounds.midY - size.height / 2 - 8,
                         width: size.width + 24, height: size.height + 16)
        NSColor.black.withAlphaComponent(0.6).setFill()
        NSBezierPath(roundedRect: box, xRadius: 8, yRadius: 8).fill()
        (text as NSString).draw(at: NSPoint(x: box.minX + 12, y: box.minY + 8), withAttributes: attrs)
    }

    // MARK: - 事件

    override func mouseDown(with event: NSEvent) {
        optionHeld = event.modifierFlags.contains(.option)
        origin = convert(event.locationInWindow, from: nil)
        current = origin
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        current = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        current = convert(event.locationInWindow, from: nil)
        let snap = optionHeld
        if let rect = selectionRect, rect.width >= 40, rect.height >= 40 {
            onFinish?(rect, false)
        } else if snap, let point = current {
            // ⌥ 单击：交给上层按点命中窗口，rect 传一个以点为中心的占位矩形
            onFinish?(CGRect(x: point.x - 1, y: point.y - 1, width: 2, height: 2), true)
        } else {
            onCancel?()
        }
        origin = nil
        current = nil
        optionHeld = false
    }

    override func rightMouseDown(with event: NSEvent) { onCancel?() }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onCancel?() } else { super.keyDown(with: event) }
    }

    override func flagsChanged(with event: NSEvent) {
        optionHeld = event.modifierFlags.contains(.option)
    }
}
