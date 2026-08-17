import AppKit
import ScreenCaptureKit

/// 多会话管理：创建入口、去重、软上限、全局操作。
final class SessionStore {
    static let shared = SessionStore()

    private(set) var sessions: [PiPSession] = []
    /// 会话增删或状态变化时通知（菜单栏据此刷新）
    var onChange: (() -> Void)?

    /// 软上限：超过后提示一次，用户确认可继续
    static let softLimit = 6

    private var screenObserver: NSObjectProtocol?

    private init() {
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Log.debug("屏幕参数变化，校正所有浮窗")
            self?.sessions.forEach { $0.handleScreenParametersChanged() }
        }
    }

    // MARK: - 查询

    var hasSessions: Bool { !sessions.isEmpty }

    func session(id: UUID) -> PiPSession? { sessions.first { $0.id == id } }

    func session(windowID: CGWindowID) -> PiPSession? {
        sessions.first { $0.sourceWindowID == windowID }
    }

    /// 菜单栏菜单将要打开时按需刷新全部窗口会话的标题（各会话内部有 0.5 秒节流）。
    /// 不用常驻定时器：标题只在菜单与悬停顶栏里可见，轮询等于白付稳态开销。
    func refreshSourceTitles() {
        sessions.forEach { $0.refreshSourceTitleNow() }
    }

    // MARK: - 创建入口

    /// 画中画当前前台窗口（热键主路径）
    func pipFrontmostWindow() {
        guard Permissions.ensureScreenRecording() else { return }
        ShareableContentStore.shared.frontmostWindow { [weak self] window in
            guard let window else {
                self?.notify(
                    title: L.t("没找到可用窗口", "No window found"),
                    message: L.t("请先把要画中画的窗口切到前台，再按下热键。",
                                 "Bring the window you want to mirror to the front, then press the hotkey.")
                )
                return
            }
            self?.pip(window: window)
        }
    }

    /// 画中画指定窗口（菜单栏选窗路径）
    func pip(window: SCWindow) {
        guard Permissions.ensureScreenRecording() else { return }

        // 去重：同一个窗口已经有浮窗了，就把它提到最前并高亮提示
        if let existing = session(windowID: window.windowID) {
            existing.bringToFront()
            existing.flashHighlight()
            return
        }
        guard confirmIfOverLimit() else { return }

        let store = ShareableContentStore.shared
        let source = store.captureSource(for: window)
        let size = window.frame.size
        guard size.width > 1, size.height > 1 else { return }

        let request = SessionRequest(
            source: source,
            baseSourceRect: CGRect(origin: .zero, size: size),
            sourcePixelSize: store.pixelSize(of: window),
            sourcePointSize: size,
            fps: Preferences.shared.fps(for: source.preferenceKey),
            autoHide: Preferences.shared.autoHideDefault,
            idleDetection: Preferences.shared.idleDetectionDefault
        )
        add(PiPSession(request: request, cascadeIndex: sessions.count))
        Log.info("新建窗口 PiP：\(source.displayTitle) @ \(request.fps.label)")
    }

    /// 区域捕获（热键 / 菜单入口）
    func beginRegionCapture() {
        guard Permissions.ensureScreenRecording() else { return }
        guard !RegionSelectionController.shared.isActive else { return }
        RegionSelectionController.shared.begin { [weak self] result in
            guard let self, let result else { return }
            self.createRegionSession(result)
        }
    }

    private func createRegionSession(_ result: RegionSelectionController.Result) {
        guard confirmIfOverLimit() else { return }
        let store = ShareableContentStore.shared
        let scale = result.screen.backingScaleFactor

        // 选区落在某个窗口内 → 用窗口流 + 窗口局部裁剪：可跟随窗口移动，被遮挡也能捕获
        if let windowID = result.hitWindowID,
           let frameTopLeft = result.hitWindowFrameTopLeft,
           let window = store.cachedWindow(id: windowID) {
            let local = Geo.windowLocalRect(
                fromScreenRect: result.screenRect,
                windowFrameTopLeft: frameTopLeft,
                primaryScreenMaxY: Geo.primaryScreenMaxY
            ).intersection(CGRect(origin: .zero, size: frameTopLeft.size))
            if local.width >= 40, local.height >= 40 {
                let source = store.captureSource(for: window)
                let request = SessionRequest(
                    source: source,
                    baseSourceRect: local,
                    sourcePixelSize: CGSize(width: local.width * scale, height: local.height * scale),
                    sourcePointSize: local.size,
                    fps: Preferences.shared.fps(for: source.preferenceKey),
                    autoHide: Preferences.shared.autoHideDefault,
                    idleDetection: Preferences.shared.idleDetectionDefault
                )
                add(PiPSession(request: request, cascadeIndex: sessions.count))
                Log.info("新建窗口内区域 PiP：\(source.displayTitle) \(Int(local.width))×\(Int(local.height))")
                return
            }
        }

        // 否则退回显示器流 + 显示器局部裁剪
        let local = Geo.sckRect(fromScreenRect: result.screenRect, on: result.screen)
        let source = CaptureSource.region(displayID: result.displayID, rect: result.screenRect)
        let request = SessionRequest(
            source: source,
            baseSourceRect: local,
            sourcePixelSize: CGSize(width: local.width * scale, height: local.height * scale),
            sourcePointSize: local.size,
            fps: Preferences.shared.fps(for: source.preferenceKey),
            autoHide: Preferences.shared.autoHideDefault,
            idleDetection: Preferences.shared.idleDetectionDefault
        )
        add(PiPSession(request: request, cascadeIndex: sessions.count))
        Log.info("新建屏幕区域 PiP：\(Int(local.width))×\(Int(local.height)) @ display \(result.displayID)")
    }

    // MARK: - 全局操作

    func closeAll() {
        for session in sessions.reversed() { session.close() }
    }

    func setAllPaused(_ paused: Bool) {
        sessions.forEach { $0.setPaused(paused) }
        onChange?()
    }

    var allPaused: Bool { !sessions.isEmpty && sessions.allSatisfy { $0.isPaused } }

    func applyLevelMode(_ mode: WindowLevelMode) {
        sessions.forEach { $0.setLevelMode(mode) }
    }

    /// 设置页改了全局「自动隐藏透明度」：写入偏好并让正处于淡出态的浮窗立即生效。
    func applyAutoHideOpacity(_ opacity: CGFloat) {
        Preferences.shared.autoHideOpacity = opacity
        sessions.forEach { $0.refreshAutoHideOpacity() }
    }

    /// 增强模式的悬停按键路由
    func handleHoverKey(_ key: EventTapManager.HoverKey, sessionID: UUID) {
        session(id: sessionID)?.applyHoverKey(key)
        onChange?()
    }

    // MARK: - 内部

    private func add(_ session: PiPSession) {
        session.onResolveDragFrame = { [weak self, weak session] proposed, flags in
            guard let self, let session else { return proposed }
            return self.resolveDragFrame(for: session, proposed: proposed, modifierFlags: flags)
        }
        session.onClose = { [weak self] closed in
            guard let self else { return }
            self.sessions.removeAll { $0 === closed }
            self.onChange?()
        }
        sessions.append(session)
        onChange?()
    }

    /// 拖动 PiP 时吸附到当前屏幕边缘或同屏的其他 PiP。
    /// 按住 Control 临时绕过磁吸，方便做像素级自由摆放。
    private func resolveDragFrame(for moving: PiPSession, proposed: CGRect,
                                  modifierFlags: NSEvent.ModifierFlags) -> CGRect {
        guard !modifierFlags.contains(.control),
              let screen = targetScreen(for: proposed) else { return proposed }
        let visibleFrame = screen.visibleFrame
        let siblings = sessions.compactMap { session -> CGRect? in
            guard session !== moving, !session.isHidden else { return nil }
            let frame = session.windowFrame
            // 只让「主要位于同一显示器」的 PiP 参与磁吸；跨屏窗口只露过来一点不算。
            guard let siblingScreen = targetScreen(for: frame),
                  isSameDisplay(siblingScreen, screen) else { return nil }
            return frame
        }
        return Geo.snappedWindowFrame(proposed, in: visibleFrame, siblings: siblings)
    }

    /// 跨屏拖动时取与窗口重叠面积最大的屏幕，避免固定使用 `NSScreen.main`。
    private func targetScreen(for frame: CGRect) -> NSScreen? {
        let screens = NSScreen.screens
        guard let best = screens.max(by: { lhs, rhs in
            // 屏幕归属用完整 frame 判定；visibleFrame 排除 Dock / 菜单栏，
            // 只适合作为最终的磁吸安全边界。
            overlapArea(lhs.frame, frame) < overlapArea(rhs.frame, frame)
        }) else { return nil }
        if overlapArea(best.frame, frame) > 0 { return best }

        // 极快拖动可能让 proposed frame 短暂落在显示器之间的空洞；
        // 此时选距窗口中心最近的屏幕，不依赖数组顺序的平局结果。
        let center = CGPoint(x: frame.midX, y: frame.midY)
        return screens.min {
            squaredDistance(from: center, to: $0.frame) < squaredDistance(from: center, to: $1.frame)
        }
    }

    private func overlapArea(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        let intersection = lhs.intersection(rhs)
        return intersection.isNull ? 0 : intersection.width * intersection.height
    }

    private func squaredDistance(from point: CGPoint, to rect: CGRect) -> CGFloat {
        let dx = max(max(rect.minX - point.x, 0), point.x - rect.maxX)
        let dy = max(max(rect.minY - point.y, 0), point.y - rect.maxY)
        return dx * dx + dy * dy
    }

    private func isSameDisplay(_ lhs: NSScreen, _ rhs: NSScreen) -> Bool {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        if let left = (lhs.deviceDescription[key] as? NSNumber)?.uint32Value,
           let right = (rhs.deviceDescription[key] as? NSNumber)?.uint32Value {
            return left == right
        }
        // 理论上 NSScreenNumber 始终存在；保留 frame 降级，避免依赖 NSScreen 对象身份稳定。
        return lhs.frame == rhs.frame
    }

    private func confirmIfOverLimit() -> Bool {
        guard sessions.count >= Self.softLimit else { return true }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L.t("已经有 \(sessions.count) 个画中画窗口",
                                "\(sessions.count) PiP windows are already open")
        alert.informativeText = L.t(
            "继续新建会明显增加 CPU 与内存占用。建议先关掉不需要的浮窗，或把帧率调低。",
            "Adding more will noticeably increase CPU and memory usage. Consider closing some or lowering the frame rate."
        )
        alert.addButton(withTitle: L.t("仍然新建", "Create anyway"))
        alert.addButton(withTitle: L.t("取消", "Cancel"))
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func notify(title: String, message: String) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: L.t("好", "OK"))
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
