import AppKit

/// 应用生命周期与模块装配。
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBar: StatusBarController?
    private var sleepObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        Geo.runSelfChecks()
        #endif
        Log.info("启动 MyWindowPip \(Updater.currentVersion)，语言：\(L.isZH ? "zh" : "en")")

        statusBar = StatusBarController()
        wireHotkeys()
        wireSettings()
        observeSleepWake()

        // 增强模式按上次的偏好恢复（权限被撤销时会自动降级）
        if Preferences.shared.enhancedMode, !EventTapManager.shared.syncWithPreferences() {
            Preferences.shared.enhancedMode = false
            Log.warn("增强模式无法启用（辅助功能权限缺失），已回退到零权限模式")
        }

        // 首次运行且未授权时：先向系统申请（这一步会弹系统授权框，并把本应用登记进
        // 「屏幕录制与系统录音」列表，用户直接开开关即可，不用手动点加号），
        // 仍未授权才显示我们的引导框。菜单栏的告警项会在下次打开菜单时自动消失。
        if !Permissions.hasScreenRecording {
            Permissions.ensureScreenRecording()
        }

        Updater.checkSilently { [weak self] info in
            self?.statusBar?.setPendingUpdate(info)
        }

        if CommandLine.arguments.contains("--smoke") { runSmokeTest() }
        if CommandLine.arguments.contains("--smoke-autohide") { runAutoHideRegression() }
    }

    /// `--smoke-autohide`：自动隐藏回归自检。
    /// 建一路 PiP → 开自动隐藏 → 把鼠标移入浮窗 → 检查是否按配置的透明度淡出并进入点击穿透
    /// → 把鼠标移出 → 检查是否完全恢复。会短暂移动鼠标指针，跑完自动退出。
    private func runAutoHideRegression() {
        Log.info("[autohide] 开始回归自检，期望淡出透明度 \(Preferences.shared.autoHideOpacity)")
        var session: PiPSession?

        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            SessionStore.shared.pipFrontmostWindow()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            session = SessionStore.shared.sessions.first
            guard let session else {
                Log.error("[autohide] 没能建立会话")
                NSApp.terminate(nil)
                return
            }
            session.toggleAutoHide()
            Log.info("[autohide] 已开启自动隐藏，把鼠标移入浮窗中心")
            Self.warpMouse(to: CGPoint(x: session.debugWindowFrame.midX,
                                       y: session.debugWindowFrame.midY))
        }
        // 开启时有 3 秒说明提示，之后才淡出，所以这里等到第 8 秒再检查
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
            guard let session else { return }
            Log.info("""
                [autohide] 悬停态：alpha=\(String(format: "%.2f", session.debugAlpha)) \
                点击穿透=\(session.debugClickThrough) 淡出中=\(session.debugAutoHideActive) \
                peek=\(session.debugPeeking)
                """)
            Log.info("[autohide] 把鼠标移出浮窗")
            let frame = session.debugWindowFrame
            Self.warpMouse(to: CGPoint(x: max(4, frame.minX - 80), y: frame.midY))
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
            guard let session else { return }
            Log.info("""
                [autohide] 离开后：alpha=\(String(format: "%.2f", session.debugAlpha)) \
                点击穿透=\(session.debugClickThrough) 淡出中=\(session.debugAutoHideActive)
                """)
            SessionStore.shared.closeAll()
            NSApp.terminate(nil)
        }
    }

    /// AppKit 坐标（左下原点）→ CG 坐标（左上原点）后移动指针。
    private static func warpMouse(to point: CGPoint) {
        let cg = CGPoint(x: point.x, y: Geo.primaryScreenMaxY - point.y)
        CGWarpMouseCursorPosition(cg)
        CGAssociateMouseAndMouseCursorPosition(1)
    }

    /// `--smoke [秒数]`：启动后自动给前台窗口开一个 PiP，跑一段时间再自动退出。
    /// 用于验证「热键路径 → 会话 → 浮窗 → 收帧」整条链路，也可用于采样 CPU 占用。
    /// 不是给终端用户用的功能。
    private func runSmokeTest() {
        let args = CommandLine.arguments
        var duration: TimeInterval = 6
        if let i = args.firstIndex(of: "--smoke"), i + 1 < args.count,
           let seconds = Double(args[i + 1]), seconds > 1 {
            duration = seconds
        }
        Log.info("[smoke] 开始集成自检，时长 \(Int(duration))s")
        var sessionCount = 1
        if let i = args.firstIndex(of: "--smoke-sessions"), i + 1 < args.count,
           let n = Int(args[i + 1]), n > 0 {
            sessionCount = min(n, SessionStore.softLimit)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            if sessionCount == 1 {
                SessionStore.shared.pipFrontmostWindow()
                return
            }
            // 多路并发：取面积最大的前 N 个普通窗口
            ShareableContentStore.shared.refresh { result in
                guard case let .success(windows) = result else { return }
                let targets = windows
                    .filter { $0.windowLayer == 0 }
                    .sorted { $0.frame.width * $0.frame.height > $1.frame.width * $1.frame.height }
                    .prefix(sessionCount)
                for window in targets { SessionStore.shared.pip(window: window) }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
            let sessions = SessionStore.shared.sessions
            Log.info("[smoke] 会话数 \(sessions.count)")
            for session in sessions {
                Log.info("[smoke] \(session.title) 运行态=\(session.runtimeState) 尺寸=\(session.debugWindowFrame)")
            }
            SessionStore.shared.closeAll()
            Log.info("[smoke] 结束，剩余会话 \(SessionStore.shared.sessions.count)")
            NSApp.terminate(nil)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        SessionStore.shared.closeAll()
        EventTapManager.shared.disable()
        HotkeyManager.shared.unregisterAll()
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    // MARK: - 装配

    private func wireHotkeys() {
        HotkeyManager.shared.onTrigger = { action in
            switch action {
            case .pip: SessionStore.shared.pipFrontmostWindow()
            case .region: SessionStore.shared.beginRegionCapture()
            case .closeAll: SessionStore.shared.closeAll()
            }
        }
        HotkeyManager.shared.start()

        EventTapManager.shared.onGlobalTrigger = { action in
            switch action {
            case .pip: SessionStore.shared.pipFrontmostWindow()
            case .region: SessionStore.shared.beginRegionCapture()
            case .closeAll: SessionStore.shared.closeAll()
            }
        }
        EventTapManager.shared.onHoverKey = { key, sessionID in
            SessionStore.shared.handleHoverKey(key, sessionID: sessionID)
        }
    }

    private func wireSettings() {
        SettingsWindowController.shared.onLevelModeChanged = { mode in
            SessionStore.shared.applyLevelMode(mode)
        }
        SettingsWindowController.shared.onAutoHideOpacityChanged = { opacity in
            SessionStore.shared.applyAutoHideOpacity(opacity)
        }
    }

    private func observeSleepWake() {
        let center = NSWorkspace.shared.notificationCenter
        sleepObserver = center.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { _ in
            Log.debug("系统即将睡眠，暂停所有浮窗")
            SessionStore.shared.setAllPaused(true)
        }
        wakeObserver = center.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { _ in
            Log.debug("系统唤醒，恢复所有浮窗")
            SessionStore.shared.setAllPaused(false)
        }
    }
}
