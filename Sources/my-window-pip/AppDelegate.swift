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

        // 首次运行且未授权时给出一次引导，避免用户按热键没反应
        if !Permissions.hasScreenRecording {
            Permissions.showScreenRecordingGuide()
        }

        Updater.checkSilently { [weak self] info in
            self?.statusBar?.setPendingUpdate(info)
        }

        if CommandLine.arguments.contains("--smoke") { runSmokeTest() }
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
