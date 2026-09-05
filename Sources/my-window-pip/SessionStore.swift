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
        pip(window: window, checkCompatibility: true, checkSoftLimit: true)
    }

    private func pip(window: SCWindow, checkCompatibility: Bool, checkSoftLimit: Bool) {
        guard Permissions.ensureScreenRecording() else { return }

        // 去重：同一个窗口已经有浮窗了，就把它提到最前并高亮提示
        if let existing = session(windowID: window.windowID) {
            existing.bringToFront()
            existing.flashHighlight()
            return
        }
        if checkSoftLimit, !confirmIfOverLimit() { return }
        if checkCompatibility, handleCompatibilityIfNeeded(for: window) { return }

        _ = createWindowSession(window)
    }

    @discardableResult
    private func createWindowSession(_ window: SCWindow) -> PiPSession? {
        let store = ShareableContentStore.shared
        let source = store.captureSource(for: window)
        let size = window.frame.size
        guard size.width > 1, size.height > 1 else { return nil }

        let request = SessionRequest(
            source: source,
            baseSourceRect: CGRect(origin: .zero, size: size),
            sourcePixelSize: store.pixelSize(of: window),
            sourcePointSize: size,
            fps: Preferences.shared.fps(for: source.preferenceKey),
            autoHide: Preferences.shared.autoHideDefault,
            idleDetection: Preferences.shared.idleDetectionDefault
        )
        let session = PiPSession(request: request, cascadeIndex: sessions.count)
        add(session)
        Log.info("新建窗口 PiP：\(source.displayTitle) @ \(request.fps.label)")
        return session
    }

    /// 对已验证会在 inactive Space 停止 repaint 的 Chromium / Electron 源应用提供兼容重启。
    /// 返回 true 表示本次创建已被重启流程或用户取消接管；false 表示继续正常创建 PiP。
    private func handleCompatibilityIfNeeded(for window: SCWindow) -> Bool {
        guard let owner = window.owningApplication,
              let application = NSRunningApplication(processIdentifier: owner.processID),
              let profile = SourceAppCompatibility.profile(for: application),
              !SourceAppCompatibility.isKnownCompatibilityLaunch(
                  profile, pid: application.processIdentifier
              ) else { return false }

        switch Preferences.shared.chromiumCompatibilityMode {
        case .off:
            return false
        case .automatic:
            startCompatibilityRelaunch(application: application, profile: profile)
            return true
        case .ask:
            break
        }

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = L.t(
            "\(profile.appName) 可能需要 Chromium 兼容模式",
            "\(profile.appName) may need Chromium compatibility mode"
        )
        alert.informativeText = profile.isVerified
            ? L.t(
                "MyWindowPip 已实际验证：以 Chromium 兼容模式重新启动 \(profile.appName) 后，可以继续捕获其他 Space 中的实时更新。重启会关闭当前 \(profile.appName) 进程和该应用已有的 PiP；重启完成后不会自动重新创建 PiP，请先确认没有未保存的工作。",
                "MyWindowPip has verified that relaunching \(profile.appName) in Chromium compatibility mode keeps live updates capturable on other Spaces. Relaunching will quit the current \(profile.appName) process and close its existing PiP windows; PiP will not be recreated automatically. Save any unfinished work first."
            )
            : L.t(
                "检测到 \(profile.appName) 使用 Chromium / Electron runtime。兼容模式会用已知的 Chromium 后台绘制开关重新启动它，以避免其他 Space 中停止刷新。重启会关闭当前进程及该应用已有的 PiP，完成后不会自动重新创建，请先确认没有未保存的工作。",
                "\(profile.appName) appears to use a Chromium / Electron runtime. Compatibility mode relaunches it with the known Chromium background-rendering switch so it can keep repainting on other Spaces. Existing PiP windows for the app are closed and are not recreated automatically. Save any unfinished work first."
            )
        alert.addButton(withTitle: L.t("以 Chromium 兼容模式重启", "Relaunch in Chromium Compatibility Mode"))
        alert.addButton(withTitle: L.t("直接创建 PiP", "Create PiP Anyway"))
        alert.addButton(withTitle: L.t("取消", "Cancel"))
        NSApp.activate(ignoringOtherApps: true)

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            startCompatibilityRelaunch(application: application, profile: profile)
            return true
        case .alertSecondButtonReturn:
            return false
        default:
            return true
        }
    }

    private func startCompatibilityRelaunch(
        application: NSRunningApplication,
        profile: SourceAppCompatibility.Profile
    ) {
        // 源应用重启会让旧 windowID 全部失效；与其在源应用恢复时自动把 PiP 接回并挡住
        // 新窗口左上角，不如在重启前主动关闭该应用的窗口 PiP。重启成功后由用户按需重新创建。
        closeWindowSessions(bundleID: profile.bundleID)
        Log.info("以 Chromium 兼容模式重启源应用；已关闭现有 PiP：\(profile.appName)")

        SourceAppCompatibility.restart(application: application, profile: profile) { [weak self] result in
            guard let self else { return }
            switch result {
            case let .success(relaunched):
                self.notify(
                    title: L.t("Chromium 兼容模式已启用", "Chromium compatibility mode is active"),
                    message: L.t(
                        "\(profile.appName) 已重新启动（PID \(relaunched.processIdentifier)）。需要时请重新创建 PiP。",
                        "\(profile.appName) relaunched (PID \(relaunched.processIdentifier)). Create a new PiP when you need it."
                    )
                )
            case let .failure(error):
                self.notify(
                    title: L.t("Chromium 兼容模式重启失败", "Chromium compatibility relaunch failed"),
                    message: error.localizedDescription
                )
            }
        }
    }

    private func closeWindowSessions(bundleID: String) {
        let matching = sessions.filter { session in
            guard case let .window(_, sessionBundleID, _, _) = session.state.source else { return false }
            return sessionBundleID == bundleID
        }
        matching.forEach { $0.close() }
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
        session.onClose = { [weak self] closed in
            guard let self else { return }
            self.sessions.removeAll { $0 === closed }
            self.onChange?()
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
