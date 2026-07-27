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

    /// 增强模式的悬停按键路由
    func handleHoverKey(_ key: EventTapManager.HoverKey, sessionID: UUID) {
        session(id: sessionID)?.applyHoverKey(key)
        onChange?()
    }

    // MARK: - 内部

    private func add(_ session: PiPSession) {
        session.onClose = { [weak self] closed in
            self?.sessions.removeAll { $0 === closed }
            self?.onChange?()
        }
        sessions.append(session)
        onChange?()
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
