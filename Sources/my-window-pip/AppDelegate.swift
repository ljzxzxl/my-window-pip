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
        statusBar?.onShowOnboarding = { [weak self] in
            self?.showOnboarding(markAsSeen: false)
        }
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

        // 权限流程走完之后再弹首启引导，避免和系统授权框叠弹
        if !Preferences.shared.hasSeenOnboarding {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                self?.showOnboarding(markAsSeen: true)
            }
        }

        Updater.checkSilently { [weak self] info in
            self?.statusBar?.setPendingUpdate(info)
        }

        if CommandLine.arguments.contains("--smoke") { runSmokeTest() }
        if CommandLine.arguments.contains("--smoke-autohide") { runAutoHideRegression() }
        if CommandLine.arguments.contains("--smoke-bar") { runTopBarRegression() }
        if CommandLine.arguments.contains("--smoke-onboarding") { runOnboardingRegression() }
        if CommandLine.arguments.contains("--smoke-update") { runUpdateRegression() }
        if CommandLine.arguments.contains("--smoke-activate") { runActivateRegression() }
        if CommandLine.arguments.contains("--smoke-mc") { runMissionControlRegression() }
        if CommandLine.arguments.contains("--smoke-renderer") { runRendererRegression() }
        if CommandLine.arguments.contains("--smoke-level") { runWindowLevelRegression() }
    }

    /// `--smoke-level`：浮窗层级回归自检。
    /// 建一路 PiP → 断言「全局悬浮」档落在 `statusBar`(25) 之上、`popUpMenu`(101) 之下——
    /// 这条边界就是「浮窗不挡菜单栏工具下拉菜单」的依据 → 切「普通置顶」断言 `.floating`(3)
    /// → 切回断言恢复。每档都要求提示条子窗口与浮窗同层，否则提示条会被浮窗自己压住。
    private func runWindowLevelRegression() {
        Log.info("[level] 开始浮窗层级回归自检")
        let popUpMenu = NSWindow.Level.popUpMenu.rawValue
        let statusBar = NSWindow.Level.statusBar.rawValue
        let expectedGlobal = WindowLevelMode.globalLevel.rawValue
        var failed = false

        func expect(_ what: String, _ actual: Int, _ expected: Int) {
            let ok = actual == expected
            if !ok { failed = true }
            Log.info("[level] \(what)=\(actual)（期望 \(expected)）\(ok ? "通过" : "失败")")
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            SessionStore.shared.pipFrontmostWindow()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            guard let session = SessionStore.shared.sessions.first else {
                Log.error("[level] 没能建立会话")
                NSApp.terminate(nil)
                return
            }
            let inRange = expectedGlobal > statusBar && expectedGlobal < popUpMenu
            if !inRange { failed = true }
            Log.info("""
                [level] 全局悬浮层级 \(expectedGlobal) 落在 statusBar(\(statusBar)) 与 \
                popUpMenu(\(popUpMenu)) 之间 \(inRange ? "通过" : "失败")
                """)

            session.setLevelMode(.global)
            expect("全局悬浮 浮窗", session.debugWindowLevel, expectedGlobal)
            expect("全局悬浮 提示条", session.debugHintWindowLevel, expectedGlobal)

            session.setLevelMode(.normal)
            expect("普通置顶 浮窗", session.debugWindowLevel, NSWindow.Level.floating.rawValue)
            expect("普通置顶 提示条", session.debugHintWindowLevel, NSWindow.Level.floating.rawValue)

            session.setLevelMode(.global)
            expect("切回全局悬浮 浮窗", session.debugWindowLevel, expectedGlobal)

            SessionStore.shared.closeAll()
            Log.info("[level] 结束，\(failed ? "有断言失败" : "全部通过")")
            NSApp.terminate(nil)
        }
    }

    /// `--smoke-renderer`：renderer 卡流检测与分级自愈回归。
    ///
    /// 两段：先用纯状态机断言时间边界（等价于单元测试，但不依赖只随完整 Xcode 提供的 XCTest），
    /// 再在真实会话上触发一次计划性 flush，断言 flush 之后帧仍能继续入队——历史上「重置时间线」
    /// 写错的典型后果就是 flush 完再也不接收新帧。
    private func runRendererRegression() {
        Log.info("[renderer] 开始卡流自愈回归自检")

        var monitor = RendererStallMonitor(timeout: 2)
        var stateMachineOK = monitor.observeNotReady(at: 0) == .none
        stateMachineOK = stateMachineOK && monitor.observeNotReady(at: 1.99) == .none
        stateMachineOK = stateMachineOK && monitor.observeNotReady(at: 2) == .flush
        stateMachineOK = stateMachineOK && monitor.observeNotReady(at: 4) == .rebuildLayer
        stateMachineOK = stateMachineOK && monitor.observeNotReady(at: 6) == .restartCapture
        stateMachineOK = stateMachineOK && monitor.observeNotReady(at: 20) == .none
        let recovered = monitor.observeReady(at: 21)
        stateMachineOK = stateMachineOK && recovered != nil && !monitor.isTrackingStall
        var lowerBound = RendererStallMonitor(timeout: 0)
        stateMachineOK = stateMachineOK && lowerBound.timeout == 0.25
        stateMachineOK = stateMachineOK && lowerBound.requestImmediateFlush(at: 1) == .flush
        Log.info("""
            [renderer] 状态机时间边界 \(stateMachineOK ? "通过" : "失败") \
            （期望 none→flush→rebuildLayer→restartCapture，ready 后复位）
            """)

        var session: PiPSession?
        var beforeFlush: UInt64 = 0

        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            SessionStore.shared.pipFrontmostWindow()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
            session = SessionStore.shared.sessions.first
            guard let session else {
                Log.error("[renderer] 没能建立会话")
                NSApp.terminate(nil)
                return
            }
            beforeFlush = session.debugEnqueuedFrameCount
            Log.info("[renderer] flush 前入队 \(beforeFlush) 帧，触发一次计划性时间线重置")
            session.debugForceDiscontinuity("smoke")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 7) {
            guard let session else { return }
            let after = session.debugEnqueuedFrameCount
            let ok = after > beforeFlush
            Log.info("""
                [renderer] flush 后入队 \(after) 帧（新增 \(after - beforeFlush)，\
                丢帧累计 \(session.debugNotReadyDropCount)）\(ok ? "继续接收（期望）" : "flush 后不再接帧（回归失败）")
                """)
            SessionStore.shared.closeAll()
            Log.info("[renderer] 结束，剩余会话 \(SessionStore.shared.sessions.count)")
            NSApp.terminate(nil)
        }
    }

    /// `--smoke-mc`：调度中心回归自检。
    /// 建一路 PiP → 记录基准矩形 → 真实开启调度中心 → 期间强制探测一次（这是 bug 的触发点）
    /// → 断言基准矩形没有被总览变换污染 → 退出调度中心 → 再断言一次。会短暂开合调度中心。
    private func runMissionControlRegression() {
        Log.info("[mc] 开始调度中心回归自检")
        var session: PiPSession?
        var initial = CGRect.zero

        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            SessionStore.shared.pipFrontmostWindow()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            session = SessionStore.shared.sessions.first
            guard let session else {
                Log.error("[mc] 没能建立会话")
                NSApp.terminate(nil)
                return
            }
            initial = session.debugBaseRect
            Log.info("""
                [mc] 初始 baseRect=\(Int(initial.width))×\(Int(initial.height)) \
                sourceRect=\(Self.describe(session.debugSourceRect))（zoom=1 期望 .zero）
                """)
            Log.info("[mc] 开启调度中心")
            Self.toggleMissionControl()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
            guard let session else { return }
            Log.info("[mc] 调度中心开着，强制探测一次源窗口")
            session.debugProbeNow()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
            guard let session else { return }
            let now = session.debugBaseRect
            let ok = abs(now.width - initial.width) < 1 && abs(now.height - initial.height) < 1
            Log.info("""
                [mc] 探测后 baseRect=\(Int(now.width))×\(Int(now.height)) \
                \(ok ? "未被污染（期望）" : "已被总览变换污染（回归失败）")
                """)
            Log.info("[mc] 退出调度中心")
            Self.toggleMissionControl()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 12) {
            guard let session else { return }
            let now = session.debugBaseRect
            let ok = abs(now.width - initial.width) < 1 && abs(now.height - initial.height) < 1
            Log.info("""
                [mc] 退出后 baseRect=\(Int(now.width))×\(Int(now.height)) \
                sourceRect=\(Self.describe(session.debugSourceRect)) \(ok ? "一致（期望）" : "不一致（回归失败）")
                """)
            SessionStore.shared.closeAll()
            NSApp.terminate(nil)
        }
    }

    private static func describe(_ rect: CGRect) -> String {
        rect == .zero ? ".zero（整窗）" : "\(Int(rect.width))×\(Int(rect.height))@(\(Int(rect.minX)),\(Int(rect.minY)))"
    }

    /// 开合调度中心：`open -a "Mission Control"` 是开关式的，调用两次即开又关。
    private static func toggleMissionControl() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-a", "Mission Control"]
        do { try process.run() } catch { Log.error("[mc] 无法触发调度中心：\(error)") }
    }

    /// `--smoke-activate`：精确回源与标题按需刷新回归自检。
    /// 建一路 PiP → 打印私有符号 / 权限状态 → 断言捕获中的 CGWindowID 能反查到 AX 窗口
    /// → 跑一次按需标题刷新 → 清理退出。不会真的抢焦点（不调用 activate）。
    private func runActivateRegression() {
        Log.info("[activate] 开始精确回源回归自检")
        Log.info("""
            [activate] AX 窗口 ID 符号=\(SourceWindowActivator.isExactMatchAvailable ? "可用" : "不可用") \
            辅助功能=\(Permissions.hasAccessibility ? "已授权" : "未授权")
            """)

        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            SessionStore.shared.pipFrontmostWindow()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            guard let session = SessionStore.shared.sessions.first,
                  let windowID = session.sourceWindowID else {
                Log.error("[activate] 没能建立窗口会话")
                NSApp.terminate(nil)
                return
            }
            guard let pid = SourceWindowActivator.ownerPID(of: windowID) else {
                Log.error("[activate] 单窗口查询拿不到 PID [windowID=\(windowID)]")
                NSApp.terminate(nil)
                return
            }
            let resolved = SourceWindowActivator.canResolveExactWindow(id: windowID, pid: pid)
            Log.info("""
                [activate] windowID=\(windowID) pid=\(pid) \
                AX 反查=\(resolved ? "命中" : "未命中")（期望：已授权辅助功能时命中）
                """)

            let before = session.title
            session.refreshSourceTitleNow()
            let cgName = SourceWindowActivator.windowInfo(of: windowID)?[
                kCGWindowName as String
            ] as? String
            Log.info("""
                [activate] 标题按需刷新：刷新前=\(before) 刷新后=\(session.title) \
                CGWindowName=\(cgName ?? "nil")
                """)

            SessionStore.shared.closeAll()
            Log.info("[activate] 结束，剩余会话 \(SessionStore.shared.sessions.count)")
            NSApp.terminate(nil)
        }
    }

    /// `--smoke-update`：更新链路回归自检。
    /// 查 Release → 下载 DMG（每 10% 打印进度）→ SHA256 校验 → 打印结果后删除文件退出。
    /// 用来验证慢链路下的超时配置与校验逻辑，不会挂载 DMG、不会弹任何窗口。
    private func runUpdateRegression() {
        Log.info("[update] 下载会话配置：\(Updater.downloadSessionDescription)")
        let started = Date()

        Updater.fetchLatest { result in
            switch result {
            case let .failure(error):
                Log.error("[update] 查询 Release 失败：\(Updater.describe(error))")
                exit(2)
            case let .success(info):
                Log.info("[update] 最新版本 \(info.version)（当前 \(Updater.currentVersion)）"
                    + " dmg=\(info.dmgURL?.lastPathComponent ?? "nil")"
                    + " sha256=\(info.sha256URL?.lastPathComponent ?? "nil")")
                guard info.dmgURL != nil else {
                    Log.error("[update] Release 里没有 DMG 资产")
                    exit(3)
                }
                Self.runUpdateDownloadProbe(info, started: started)
            }
        }
    }

    private static func runUpdateDownloadProbe(_ info: ReleaseInfo, started: Date) {
        var lastBucket = -1
        Updater.startDownloadForProbe(
            info,
            onProgress: { written, total in
                guard total > 0 else { return }
                let bucket = Int(Double(written) / Double(total) * 10)
                guard bucket != lastBucket else { return }
                lastBucket = bucket
                let elapsed = String(format: "%.1f", Date().timeIntervalSince(started))
                Log.info("[update] 进度 \(bucket * 10)%（\(written)/\(total) 字节，\(elapsed)s）")
            },
            onFinished: { result in
                let elapsed = String(format: "%.1f", Date().timeIntervalSince(started))
                switch result {
                case let .failure(error):
                    Log.error("[update] 下载失败（\(elapsed)s）：\(Updater.describe(error))")
                    exit(4)
                case let .success(file):
                    Log.info("[update] 下载完成（\(elapsed)s）：\(file.path)")
                    guard let shaURL = info.sha256URL else {
                        Log.warn("[update] 无 .sha256 资产，跳过校验")
                        try? FileManager.default.removeItem(at: file)
                        Log.info("[update] 自检通过（未校验）")
                        exit(0)
                    }
                    URLSession.shared.dataTask(with: shaURL) { data, _, _ in
                        let expected = data.flatMap { String(data: $0, encoding: .utf8) }?
                            .split(whereSeparator: { $0 == " " || $0 == "\n" }).first.map(String.init)?
                            .lowercased() ?? ""
                        let actual = ((try? Updater.sha256(ofFileAt: file)) ?? "").lowercased()
                        Log.info("[update] SHA256 期望=\(expected.prefix(16))… 实际=\(actual.prefix(16))…")
                        try? FileManager.default.removeItem(at: file)
                        if !expected.isEmpty, expected == actual {
                            Log.info("[update] 自检通过：下载 + 校验均正常")
                            exit(0)
                        } else {
                            Log.error("[update] SHA256 校验失败")
                            exit(5)
                        }
                    }.resume()
                }
            }
        )
    }

    /// `--smoke-onboarding`：首启引导回归自检。展示引导 → 断言窗口已出现 → 关闭 → 断言已清理。
    private func runOnboardingRegression() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            let anchor = self?.statusBar?.statusItemScreenFrame
            Log.info("[onboarding] 菜单栏图标位置：\(anchor.map { "\($0)" } ?? "未取到（走降级布局）")")
            self?.showOnboarding(markAsSeen: false)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            let visibleWindows = NSApp.windows.filter { $0.isVisible }.count
            Log.info("[onboarding] isVisible=\(OnboardingOverlay.isVisible) 可见窗口数=\(visibleWindows)（期望 ≥ 屏幕数）")
            OnboardingOverlay.dismiss()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.5) {
            Log.info("[onboarding] 关闭后 isVisible=\(OnboardingOverlay.isVisible)（期望 false）"
                + "，可见窗口数=\(NSApp.windows.filter { $0.isVisible }.count)")
            NSApp.terminate(nil)
        }
    }

    /// `--smoke-bar`：顶栏热区回归自检。
    /// 建一路 PiP → 开自动隐藏 → 指针移到顶栏热区（应完整可操作）→ 移到画面区域（应淡出并穿透）
    /// → 移出浮窗（应完全恢复）。会短暂移动鼠标指针，跑完自动退出。
    private func runTopBarRegression() {
        Log.info("[bar] 开始顶栏热区回归自检")
        var session: PiPSession?

        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            SessionStore.shared.pipFrontmostWindow()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            session = SessionStore.shared.sessions.first
            guard let session else {
                Log.error("[bar] 没能建立会话")
                NSApp.terminate(nil)
                return
            }
            session.toggleAutoHide()
            // 先等 3 秒说明提示过去，再把指针移进画面区域，确认淡出生效
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) {
                Self.warpMouse(to: CGPoint(x: session.debugWindowFrame.midX,
                                           y: session.debugWindowFrame.minY + 20))
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 9) {
            guard let session else { return }
            Log.info("""
                [bar] 画面区域：alpha=\(String(format: "%.2f", session.debugAlpha)) \
                点击穿透=\(session.debugClickThrough)（期望淡出 + 穿透开启）
                """)
            guard let bar = session.debugBarScreenFrame else {
                Log.error("[bar] 拿不到顶栏热区")
                return
            }
            Log.info("[bar] 指针移到顶栏热区中心")
            Self.warpMouse(to: CGPoint(x: bar.midX, y: bar.midY))
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 11) {
            guard let session else { return }
            Log.info("""
                [bar] 顶栏热区：alpha=\(String(format: "%.2f", session.debugAlpha)) \
                点击穿透=\(session.debugClickThrough)（期望 alpha=1.00 + 穿透关闭）
                """)
            let frame = session.debugWindowFrame
            Log.info("[bar] 指针移出浮窗")
            Self.warpMouse(to: CGPoint(x: max(4, frame.minX - 80), y: frame.midY))
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 13) {
            guard let session else { return }
            Log.info("""
                [bar] 移出后：alpha=\(String(format: "%.2f", session.debugAlpha)) \
                点击穿透=\(session.debugClickThrough)（期望 alpha=1.00 + 穿透关闭）
                """)
            SessionStore.shared.closeAll()
            NSApp.terminate(nil)
        }
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
        Updater.cancelDownload()
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

    /// 首启引导：LSUIElement 应用没有主窗口，必须明确告诉用户「已经在后台跑起来了，入口在菜单栏」。
    /// 菜单栏图标刚创建时还没完成布局，拿不到位置就等一拍再试一次，尽量让箭头能指准。
    private func showOnboarding(markAsSeen: Bool, retry: Bool = true) {
        let anchor = statusBar?.statusItemScreenFrame
        if anchor == nil, retry {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                self?.showOnboarding(markAsSeen: markAsSeen, retry: false)
            }
            return
        }
        OnboardingOverlay.show(
            anchor: anchor,
            onOpenMenu: { [weak self] in
                // 关闭引导后紧接着弹菜单，用户能立刻看到「选择窗口」
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    self?.statusBar?.openMenu()
                }
            },
            onDismiss: {
                if markAsSeen { Preferences.shared.hasSeenOnboarding = true }
            }
        )
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
