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

        let store = ShareableContentStore.shared
        let source = store.captureSource(for: window)

        // 去重：同一个窗口已经有浮窗了，就把它提到最前并高亮提示。
        // WindowServer 可能把已销毁窗口的 ID 分配给别的应用，此时旧会话正在等待重连，
        // 直接按 ID 去重会把新窗口错认成它；再比一次所属应用即可排除。
        if let existing = session(windowID: window.windowID),
           existing.positionFallbackPreferenceKey == source.preferenceKey {
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
        let positionIdentity = PositionMemoryIdentity.window(
            appPreferenceKey: source.preferenceKey, windowID: window.windowID
        )

        let request = SessionRequest(
            source: source,
            positionIdentity: positionIdentity,
            baseSourceRect: CGRect(origin: .zero, size: size),
            sourcePixelSize: store.pixelSize(of: window),
            sourcePointSize: size,
            fps: Preferences.shared.fps(for: source.preferenceKey),
            autoHide: Preferences.shared.autoHideDefault,
            idleDetection: Preferences.shared.idleDetectionDefault
        )
        let session = PiPSession(
            request: request,
            initialOrigin: initialOrigin(for: positionIdentity),
            cascadeIndex: sessions.count
        )
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

        switch SourceAppCompatibility.relaunchDecision(
            mode: Preferences.shared.chromiumCompatibilityMode,
            isVerified: profile.isVerified
        ) {
        case .skip:
            return false
        case .relaunch:
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
        // 记录到 debug 级别：info 会进常驻日志，没必要长期留存用户在跑哪些应用。
        Log.debug("以 Chromium 兼容模式重启源应用；已关闭现有 PiP：\(profile.appName)")

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

        // 默认必须是显示器合成流：用户框选的是屏幕上的一块区域，同屏的悬浮字幕、
        // 翻译窗口、菜单栏都要进画面。只有 ⌥ 单击（或设置里的兼容开关）才升级成单窗口流，
        // 否则全屏 VLC / IINA 会把整块屏幕吃掉（issue #13）。
        let wantsWindowStream = RegionCapturePolicy.usesWindowStream(
            snapWindow: result.prefersWindowCapture,
            followsWindowByDefault: Preferences.shared.regionFollowsWindow,
            hitWindowID: result.hitWindowID
        )
        if wantsWindowStream, let windowID = result.hitWindowID {
            createWindowRegionSession(result, windowID: windowID)
            return
        }
        createDisplayRegionSession(result)
    }

    /// 显式要求「只要这个窗口」时才走单窗口流（跟随窗口、被遮挡也能拍）。
    private func createWindowRegionSession(_ result: RegionSelectionController.Result,
                                           windowID: CGWindowID) {
        // 异步取最新的 SCWindow：直接用 1 秒 TTL 缓存里的旧对象构造
        // desktopIndependentWindow 过滤器，在 Space 切换 / 显示器重排后可能指向已销毁窗口。
        ShareableContentStore.shared.window(id: windowID) { [weak self] window in
            guard let self else { return }
            guard let window else {
                Log.warn("窗口流目标已失效，回退到显示器合成流")
                self.createDisplayRegionSession(result)
                return
            }
            let full = CGRect(origin: .zero, size: window.frame.size)
            let local: CGRect
            if result.prefersWindowCapture {
                // ⌥ 单击选中整个窗口：不做局部裁剪，让 SCK 输出完整窗口内容
                local = full
            } else {
                local = Geo.windowLocalRect(
                    fromScreenRect: result.screenRect,
                    windowFrameTopLeft: window.frame,
                    primaryScreenMaxY: Geo.primaryScreenMaxY
                ).intersection(full)
                guard local.width >= 40, local.height >= 40 else {
                    self.createDisplayRegionSession(result)
                    return
                }
            }

            let scale = result.screen.backingScaleFactor
            let source = ShareableContentStore.shared.captureSource(for: window)
            let positionIdentity = PositionMemoryIdentity.windowRegion(
                appPreferenceKey: source.preferenceKey, windowID: window.windowID, rect: local
            )
            let request = SessionRequest(
                source: source,
                positionIdentity: positionIdentity,
                baseSourceRect: local,
                sourcePixelSize: CGSize(width: local.width * scale, height: local.height * scale),
                sourcePointSize: local.size,
                fps: Preferences.shared.fps(for: source.preferenceKey),
                autoHide: Preferences.shared.autoHideDefault,
                idleDetection: Preferences.shared.idleDetectionDefault
            )
            add(PiPSession(
                request: request,
                initialOrigin: initialOrigin(for: positionIdentity),
                cascadeIndex: sessions.count
            ))
            Log.info("新建窗口内区域 PiP：\(source.displayTitle) \(Int(local.width))×\(Int(local.height))")
        }
    }

    /// 显示器流 + 显示器局部裁剪：捕获选区范围内的完整合成画面。
    private func createDisplayRegionSession(_ result: RegionSelectionController.Result) {
        let scale = result.screen.backingScaleFactor
        let local = Geo.sckRect(fromScreenRect: result.screenRect, on: result.screen)
        let source = CaptureSource.region(displayID: result.displayID, rect: result.screenRect)
        let positionIdentity = PositionMemoryIdentity.displayRegion(
            displayID: result.displayID, rect: result.screenRect
        )
        let request = SessionRequest(
            source: source,
            positionIdentity: positionIdentity,
            baseSourceRect: local,
            sourcePixelSize: CGSize(width: local.width * scale, height: local.height * scale),
            sourcePointSize: local.size,
            fps: Preferences.shared.fps(for: source.preferenceKey),
            autoHide: Preferences.shared.autoHideDefault,
            idleDetection: Preferences.shared.idleDetectionDefault
        )
        add(PiPSession(
            request: request,
            initialOrigin: initialOrigin(for: positionIdentity),
            cascadeIndex: sessions.count
        ))
        Log.info("新建屏幕区域 PiP：\(Int(local.width))×\(Int(local.height)) @ display \(result.displayID)")
    }

    // MARK: - 整屏捕获（issue #12）

    /// 当前可捕获的显示器列表（菜单栏子菜单与热键共用）。
    static func availableDisplays() -> [DisplayTarget] {
        let mainID = CGMainDisplayID()
        return NSScreen.screens.map { screen in
            let id = RegionSelectionController.displayID(of: screen)
            return DisplayTarget(
                displayID: id,
                name: screen.localizedName,
                frame: screen.frame,
                isMain: id == mainID,
                isBuiltin: CGDisplayIsBuiltin(id) != 0
            )
        }
    }

    /// 热键入口：一键捕获外接显示器（或上次在菜单栏选中的那块），无需框选。
    func capturePreferredDisplay() {
        let targets = Self.availableDisplays()
        guard let target = DisplayCaptureTarget.hotkeyTarget(
            in: targets, lastUsedID: Preferences.shared.lastCaptureDisplayID
        ) else {
            notify(title: L.t("没有可用的显示器", "No display available"),
                   message: L.t("系统当前没有报告任何已连接的显示器。",
                                "macOS is not reporting any connected display."))
            return
        }
        createDisplaySession(target)
    }

    /// 菜单栏入口：捕获指定的整块显示器。
    func captureDisplay(displayID: CGDirectDisplayID) {
        guard let target = DisplayCaptureTarget.withID(displayID, in: Self.availableDisplays()) else {
            Log.warn("显示器 \(displayID) 已断开，忽略整屏捕获")
            return
        }
        createDisplaySession(target)
    }

    private func createDisplaySession(_ target: DisplayTarget) {
        guard Permissions.ensureScreenRecording() else { return }
        guard let screen = NSScreen.screens.first(where: {
            RegionSelectionController.displayID(of: $0) == target.displayID
        }) else {
            Log.warn("显示器 \(target.displayID) 已断开，忽略整屏捕获")
            return
        }

        // 同一块显示器已经有整屏浮窗时直接提到最前，避免热键连按堆出一排重复浮窗。
        if let existing = sessions.first(where: { session in
            guard case let .display(displayID, _, _) = session.state.source else { return false }
            return displayID == target.displayID
        }) {
            existing.bringToFront()
            existing.flashHighlight()
            return
        }
        guard confirmIfOverLimit() else { return }
        Preferences.shared.lastCaptureDisplayID = target.displayID

        let scale = screen.backingScaleFactor
        // 整屏在显示器局部坐标里就是 (0, 0, w, h)；SCK 侧用 .zero 表示「完整内容」。
        let local = Geo.sckRect(fromScreenRect: screen.frame, on: screen)
        let source = CaptureSource.display(
            displayID: target.displayID, name: target.name, rect: screen.frame
        )
        let positionIdentity = PositionMemoryIdentity.display(displayID: target.displayID)
        let request = SessionRequest(
            source: source,
            positionIdentity: positionIdentity,
            baseSourceRect: local,
            sourcePixelSize: CGSize(width: local.width * scale, height: local.height * scale),
            sourcePointSize: local.size,
            fps: Preferences.shared.fps(for: source.preferenceKey),
            autoHide: Preferences.shared.autoHideDefault,
            idleDetection: Preferences.shared.idleDetectionDefault
        )
        add(PiPSession(
            request: request,
            initialOrigin: initialOrigin(for: positionIdentity),
            cascadeIndex: sessions.count
        ))
        Log.info("新建整屏 PiP：\(target.name) \(target.dimensions) @ display \(target.displayID)")
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

    /// 精确的捕获目标位置优先。没有记录且同一回退命名空间已有 PiP 时，不复用旧版位置，
    /// 让 `PiPWindowController` 的 cascade 布局生效；首个目标仍可沿用旧版本记住的位置。
    private func initialOrigin(for identity: PositionMemoryIdentity) -> CGPoint? {
        let prefs = Preferences.shared
        let exact = prefs.origin(for: identity)
        let hasActiveSibling = sessions.contains {
            $0.positionFallbackPreferenceKey == identity.fallbackPreferenceKey
        }
        return Self.selectInitialOrigin(
            exactOrigin: exact,
            fallbackOrigin: prefs.fallbackOrigin(for: identity),
            hasActiveSibling: hasActiveSibling
        )
    }

    static func selectInitialOrigin(exactOrigin: CGPoint?, fallbackOrigin: CGPoint?,
                                    hasActiveSibling: Bool) -> CGPoint? {
        if let exactOrigin { return exactOrigin }
        return hasActiveSibling ? nil : fallbackOrigin
    }

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
            guard session !== moving, session.isVisibleForSnapping else { return nil }
            let frame = session.windowFrame
            // 只让「当前 Space 实际可见且主要位于同一显示器」的 PiP 参与磁吸；
            // 跨屏窗口只露过来一点不算，非活动 Space 的旧 frame 也不会产生幽灵吸附。
            guard let siblingScreen = targetScreen(for: frame),
                  isSameDisplay(siblingScreen, screen) else { return nil }
            return frame
        }
        // 使用目标显示器自己的可用区域：零间隙贴边，同时不侵入菜单栏或 Dock。
        return Geo.snappedWindowFrame(proposed, in: visibleFrame, siblings: siblings)
    }

    /// 跨屏拖动时取与窗口重叠面积最大的屏幕，避免固定使用 `NSScreen.main`。
    /// 屏幕归属用完整 frame 判定；`visibleFrame` 排除 Dock / 菜单栏，
    /// 只适合作为最终的磁吸安全边界。
    private func targetScreen(for frame: CGRect) -> NSScreen? {
        let screens = NSScreen.screens
        guard let index = Geo.indexOfScreen(
            containing: frame,
            screenFrames: screens.map(\.frame)
        ) else { return nil }
        return screens[index]
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
