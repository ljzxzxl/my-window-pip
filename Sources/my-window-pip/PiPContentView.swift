import AVFoundation
import AppKit
import CoreMedia

/// PiP 浮窗的内容视图。
///
/// 职责：
/// 1. 宿主 `AVSampleBufferDisplayLayer`，把捕获层送来的 `CMSampleBuffer` 直接 enqueue（零转码零拷贝）；
/// 2. 处理鼠标 / 键盘手势，并把手势换算成「源画面归一化坐标」后经回调交给上层。
///
/// 坐标系约定：本视图**不翻转**（`isFlipped == false`），与 `Geo` 约定的「视图坐标左下原点」一致；
/// 所有视图坐标 → 源归一化坐标的换算一律走 `Geo`，此文件内不写任何手工 Y 翻转。
final class PiPContentView: NSView {

    // MARK: - 对外回调

    /// 请求缩放：(新倍率, 新锚点 —— 源画面归一化坐标，左上原点)
    var onRequestZoom: ((CGFloat, CGPoint) -> Void)?
    /// 请求平移：归一化视野位移（相对当前可见视野的比例，正值 = 视野向右/向下移动）
    var onRequestPan: ((CGSize) -> Void)?
    var onRequestZoomReset: (() -> Void)?
    var onRequestClose: (() -> Void)?
    var onRequestCycleFPS: (() -> Void)?
    var onRequestToggleIdleDetection: (() -> Void)?
    var onRequestTogglePause: (() -> Void)?
    /// 手动拖动窗口结束（本次按下确实移动过窗口）：上层据此持久化位置、处理跨屏 scale 变化
    var onDidDragWindow: (() -> Void)?
    /// 干净的单击（未拖动、`clickCount == 1`、无 Cmd/⌥/⌃/⇧）：请求切回源应用
    var onRequestActivateSource: (() -> Void)?

    // MARK: - 渲染

    private let displayLayer = AVSampleBufferDisplayLayer()
    /// Cmd + 拖拽的框选提示层
    private let selectionLayer = CAShapeLayer()
    /// display layer 进入 failed 状态时只打一次日志，避免刷屏
    private var didLogRenderFailure = false

    // MARK: - 手势换算所需的状态（由 controller 注入）

    private var zoom: CGFloat = PiPSessionState.minZoom
    private var anchor = CGPoint(x: 0.5, y: 0.5)
    private var aspect = CGSize(width: 16, height: 9)

    // MARK: - 框选

    private var selectionStart: CGPoint?
    private var isSelecting = false

    // MARK: - 手动拖窗 / 单击判定

    /// 按下时的鼠标屏幕位置。位移一律按「当前 - 起点」的累计差值算，不用逐次增量，避免抖动。
    private var dragStartMouseInScreen: CGPoint?
    /// 按下时的窗口原点（屏幕坐标）
    private var dragStartWindowOrigin: CGPoint?
    /// 本次按下是否已判定为拖动
    private var didDrag = false
    /// 判定为拖动的最小位移（点）
    private static let dragThreshold: CGFloat = 3
    /// 会阻止「单击回源」的修饰键：带这些键的点击属于其它手势
    private static let activateBlockingFlags: NSEvent.ModifierFlags = [.command, .option, .control, .shift]

    // MARK: - 60Hz 节流合并

    private var pendingPan: CGSize = .zero
    private var pendingZoom: (zoom: CGFloat, anchor: CGPoint)?
    private var flushScheduled = false

    // MARK: - 鼠标状态

    private var isMouseInside = false
    private var mouseTracking: NSTrackingArea?

    /// 键盘调倍率的步进系数
    private static let keyboardZoomFactor: CGFloat = 1.25
    /// 滚轮调倍率的灵敏度（精密滚动 / 普通滚轮分别取值）
    private static let preciseZoomUnit: CGFloat = 0.01
    private static let coarseZoomUnit: CGFloat = 0.1

    // MARK: - 初始化

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay

        displayLayer.videoGravity = .resizeAspect
        displayLayer.backgroundColor = NSColor.black.cgColor

        // 固定色值而非语义色：CALayer 需要 CGColor，避免随外观变化产生解析歧义
        selectionLayer.fillColor = NSColor(calibratedWhite: 1, alpha: 0.16).cgColor
        selectionLayer.strokeColor = NSColor(calibratedRed: 0.29, green: 0.63, blue: 1, alpha: 0.95).cgColor
        selectionLayer.lineWidth = 1.5
        selectionLayer.isHidden = true

        attachLayersIfNeeded()
    }

    required init?(coder: NSCoder) {
        fatalError("PiPContentView 仅支持代码创建（本项目无 xib/storyboard）")
    }

    // MARK: - 布局

    override func layout() {
        super.layout()
        attachLayersIfNeeded()
        displayLayer.frame = bounds
        selectionLayer.frame = bounds
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let scale = window?.backingScaleFactor ?? 2
        layer?.contentsScale = scale
        displayLayer.contentsScale = scale
        selectionLayer.contentsScale = scale
    }

    private func attachLayersIfNeeded() {
        guard let root = layer else { return }
        root.backgroundColor = NSColor.black.cgColor
        if displayLayer.superlayer == nil { root.addSublayer(displayLayer) }
        // 框选层始终在画面之上
        if selectionLayer.superlayer == nil { root.addSublayer(selectionLayer) }
        selectionLayer.zPosition = 10
    }

    // MARK: - 状态注入

    /// 由 controller 注入当前会话状态，供手势换算使用。
    func update(state: PiPSessionState, aspect: CGSize) {
        zoom = Geo.clampZoom(state.zoom)
        anchor = Geo.clampAnchor(state.anchor, zoom: zoom)
        update(aspect: aspect)
    }

    /// 仅更新宽高比（源尺寸变化时，controller 可能还没有可用的会话状态）。
    func update(aspect newAspect: CGSize) {
        guard newAspect.width > 0, newAspect.height > 0 else { return }
        aspect = newAspect
    }

    // MARK: - 帧入队

    /// 主线程调用。宁丢帧不积压：layer 不接收时直接丢弃当前帧。
    func enqueue(_ sampleBuffer: CMSampleBuffer) {
        guard CMSampleBufferIsValid(sampleBuffer) else { return }

        // failed 状态必须先 flush 才能恢复解码
        if displayLayer.status == .failed {
            if !didLogRenderFailure {
                didLogRenderFailure = true
                Log.warn("display layer 进入 failed 状态，尝试 flush 恢复：\(displayLayer.error?.localizedDescription ?? "-")")
            }
            displayLayer.flush()
            return
        }
        didLogRenderFailure = false

        guard displayLayer.isReadyForMoreMediaData else { return }
        displayLayer.enqueue(sampleBuffer)
    }

    /// 关闭 / 重连时清空 layer 与所有待处理手势。
    func flushAndReset() {
        displayLayer.flushAndRemoveImage()
        cancelSelection()
        resetDragTracking()
        pendingPan = .zero
        pendingZoom = nil
        didLogRenderFailure = false
    }

    // MARK: - 响应链

    override var acceptsFirstResponder: Bool { true }

    /// 浮窗是 nonactivating 的，未获得 key 状态时也要能直接响应第一次点击。
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// 关闭系统的「背景拖动」自动接管（窗口侧 `isMovableByWindowBackground` 也已置为 false）：
    /// 带 Cmd → 框选；不带 Cmd → 本视图自己算位移移动窗口。
    /// 系统背景拖动会在 mouseDown 前吞掉事件序列，既收不到 Cmd 框选，也拿不到干净的 mouseUp（单击回源要用）。
    override var mouseDownCanMoveWindow: Bool { false }

    // MARK: - 鼠标：框选 / 拖动 / 单击回源 / 复位

    override func mouseDown(with event: NSEvent) {
        let isCommand = event.modifierFlags.contains(.command)

        // Cmd + 双击 → 复位缩放（优先级最高，与改造前一致）
        if isCommand && event.clickCount >= 2 {
            cancelSelection()
            resetDragTracking()
            onRequestZoomReset?()
            return
        }

        if isCommand {
            resetDragTracking()
            selectionStart = convert(event.locationInWindow, from: nil)
            isSelecting = true
            selectionLayer.path = nil
            selectionLayer.isHidden = false
            return
        }

        // 无 Cmd：开始跟踪「拖动 or 单击」，具体由 mouseDragged / mouseUp 判定
        cancelSelection()
        didDrag = false
        dragStartMouseInScreen = window?.convertPoint(toScreen: event.locationInWindow)
        dragStartWindowOrigin = window?.frame.origin
    }

    override func mouseDragged(with event: NSEvent) {
        if isSelecting, let start = selectionStart {
            let current = convert(event.locationInWindow, from: nil)
            selectionLayer.path = CGPath(rect: Self.rect(from: start, to: current), transform: nil)
            return
        }

        guard let window,
              let startMouse = dragStartMouseInScreen,
              let startOrigin = dragStartWindowOrigin else {
            super.mouseDragged(with: event)
            return
        }

        // locationInWindow 是事件发生时相对窗口的坐标，转屏幕后即为真实全局位置：
        // 即使窗口已在本次拖动中移动过，用「起点 → 当前」的累计差值也不会漂移。
        let current = window.convertPoint(toScreen: event.locationInWindow)
        let dx = current.x - startMouse.x
        let dy = current.y - startMouse.y
        if !didDrag {
            guard hypot(dx, dy) > Self.dragThreshold else { return }
            didDrag = true
        }

        var frame = window.frame
        frame.origin = CGPoint(x: (startOrigin.x + dx).rounded(), y: (startOrigin.y + dy).rounded())
        // 安全网：只有整窗跑到所有屏幕可见区域之外时才会被拉回，正常拖动（含跨屏）不受影响
        window.setFrameOrigin(Geo.constrainToVisibleScreens(frame).origin)
    }

    override func mouseUp(with event: NSEvent) {
        if isSelecting, let start = selectionStart {
            let selection = Self.rect(from: start, to: convert(event.locationInWindow, from: nil))
            cancelSelection()

            guard let result = Geo.zoomAndAnchor(forSelection: selection, aspect: aspect, bounds: bounds,
                                                 currentZoom: zoom, currentAnchor: anchor) else { return }
            // 本地先行更新，避免连续操作时用到过期的 zoom/anchor
            zoom = result.0
            anchor = result.1
            pendingZoom = nil
            onRequestZoom?(result.0, result.1)
            return
        }

        let wasTracking = dragStartMouseInScreen != nil
        let dragged = didDrag
        resetDragTracking()

        guard wasTracking else {
            super.mouseUp(with: event)
            return
        }
        if dragged {
            onDidDragWindow?()
            return
        }

        // 干净的单击才回源：双击 / 带修饰键的点击都留给其它手势
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard event.clickCount == 1, flags.isDisjoint(with: Self.activateBlockingFlags) else { return }
        onRequestActivateSource?()
    }

    private func resetDragTracking() {
        didDrag = false
        dragStartMouseInScreen = nil
        dragStartWindowOrigin = nil
    }

    private func cancelSelection() {
        isSelecting = false
        selectionStart = nil
        selectionLayer.path = nil
        selectionLayer.isHidden = true
    }

    private static func rect(from a: CGPoint, to b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y),
               width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    // MARK: - 滚轮：平移 / 调倍率

    override func scrollWheel(with event: NSEvent) {
        let content = Geo.contentRect(aspect: aspect, in: bounds)
        guard content.width > 1, content.height > 1 else { return }

        if event.modifierFlags.contains(.command) {
            zoomByScroll(event)
        } else {
            panByScroll(event, content: content)
        }
    }

    private func zoomByScroll(_ event: NSEvent) {
        let unit = event.hasPreciseScrollingDeltas ? Self.preciseZoomUnit : Self.coarseZoomUnit
        let step = event.scrollingDeltaY * unit
        guard abs(step) > 0.0001 else { return }

        let baseZoom = pendingZoom?.zoom ?? zoom
        let baseAnchor = pendingZoom?.anchor ?? anchor
        let target = Geo.clampZoom(baseZoom * (1 + step))
        guard abs(target - baseZoom) > 0.0001 else { return }

        // 指针位置 → 可见视野归一化 → 源画面归一化（全部走 Geo）
        let point = convert(event.locationInWindow, from: nil)
        var pointerSource = baseAnchor
        if let visible = Geo.viewPointToVisibleNorm(point, aspect: aspect, bounds: bounds) {
            pointerSource = Geo.visibleNormToSourceNorm(visible, zoom: baseZoom, anchor: baseAnchor)
        }
        let newAnchor = Geo.anchor(zoomingFrom: baseAnchor, oldZoom: baseZoom,
                                   to: target, pointerNorm: pointerSource)
        pendingZoom = (target, newAnchor)
        scheduleFlush()
    }

    private func panByScroll(_ event: NSEvent, content: CGRect) {
        // 未放大时没有可平移的余量
        guard (pendingZoom?.zoom ?? zoom) > PiPSessionState.minZoom + 0.0001 else { return }

        // scrollingDelta 已由系统按「自然滚动」偏好处理过，这里不再手工反向；
        // 取负号是因为「内容跟手」= 视野朝反方向移动，而 anchor 用左上原点（Y 向下为正）。
        let delta = CGSize(width: -event.scrollingDeltaX / content.width,
                           height: -event.scrollingDeltaY / content.height)
        guard abs(delta.width) > 0 || abs(delta.height) > 0 else { return }
        pendingPan.width += delta.width
        pendingPan.height += delta.height
        scheduleFlush()
    }

    /// 把一帧（约 16.7ms）内的多次滚轮事件合并成一次回调。
    private func scheduleFlush() {
        guard !flushScheduled else { return }
        flushScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 60.0) { [weak self] in
            self?.flushPendingGestures()
        }
    }

    private func flushPendingGestures() {
        flushScheduled = false

        if let target = pendingZoom {
            pendingZoom = nil
            zoom = target.zoom
            anchor = target.anchor
            onRequestZoom?(target.zoom, target.anchor)
        }

        let pan = pendingPan
        pendingPan = .zero
        if abs(pan.width) > 1e-6 || abs(pan.height) > 1e-6 {
            anchor = Geo.anchor(anchor, pannedBy: pan, zoom: zoom)
            onRequestPan?(pan)
        }
    }

    // MARK: - 键盘（App 处于活动状态时可用；不是唯一入口）

    override func keyDown(with event: NSEvent) {
        switch event.charactersIgnoringModifiers?.lowercased() ?? "" {
        case "=", "+":
            stepZoom(Self.keyboardZoomFactor)
        case "-", "_":
            stepZoom(1 / Self.keyboardZoomFactor)
        case "f":
            onRequestCycleFPS?()
        case "d":
            onRequestToggleIdleDetection?()
        case " ":
            onRequestTogglePause?()
        case "\u{1B}":      // esc
            onRequestClose?()
        case "\u{7F}", "\u{8}", "\u{F728}":  // delete / backspace / forward delete
            onRequestClose?()
        default:
            super.keyDown(with: event)
        }
    }

    /// 键盘调倍率：锚点保持不动，只在合法范围内收拢。
    private func stepZoom(_ factor: CGFloat) {
        let baseZoom = pendingZoom?.zoom ?? zoom
        let baseAnchor = pendingZoom?.anchor ?? anchor
        let target = Geo.clampZoom(baseZoom * factor)
        guard abs(target - baseZoom) > 0.0001 else { return }
        pendingZoom = (target, Geo.clampAnchor(baseAnchor, zoom: target))
        scheduleFlush()
    }

    // MARK: - 光标：hover 不改光标，按下 Cmd 时切十字

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = mouseTracking { removeTrackingArea(existing) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .cursorUpdate, .activeAlways, .inVisibleRect],
            owner: self, userInfo: nil
        )
        addTrackingArea(area)
        mouseTracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        isMouseInside = true
        super.mouseEntered(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        isMouseInside = false
        NSCursor.arrow.set()
        super.mouseExited(with: event)
    }

    override func cursorUpdate(with event: NSEvent) {
        if event.modifierFlags.contains(.command) {
            NSCursor.crosshair.set()
        } else {
            super.cursorUpdate(with: event)
        }
    }

    override func flagsChanged(with event: NSEvent) {
        // 已开始的框选不因中途松开 Cmd 而中断（用户常在抬起鼠标前先松 Cmd）
        if isMouseInside && !isSelecting {
            if event.modifierFlags.contains(.command) {
                NSCursor.crosshair.set()
            } else {
                NSCursor.arrow.set()
            }
        }
        super.flagsChanged(with: event)
    }
}
