import AppKit
import CoreMedia
import ScreenCaptureKit

/// 单个 PiP 会话：串联「捕获引擎 ←→ 状态 ←→ 浮窗」，是三者唯一的中转站。
/// 捕获层与展示层互不知道对方的存在，全部经本类转发。
final class PiPSession: NSObject, CaptureEngineDelegate, PiPWindowDelegate {

    let id = UUID()
    private(set) var state: PiPSessionState
    private(set) var runtimeState: SessionRuntimeState = .streaming

    /// 捕获基准矩形（源坐标系、左上原点、逻辑点），缩放平移都在其内部进行
    private var baseRect: CGRect
    private var sourcePixelSize: CGSize
    /// 与显示标题解耦的位置身份；窗口重匹配时只更新其中的 CGWindowID。
    private var positionIdentity: PositionMemoryIdentity

    private let engine = CaptureEngine()
    private let windowController: PiPWindowController
    private let idleDetector: IdleDetector

    /// 关闭回调（由 SessionStore 注入）
    var onClose: ((PiPSession) -> Void)?

    // 运行期辅助状态
    private var isAutoHidden = false
    /// 自动隐藏淡出后的「临时唤回」原因：按住 ⌥，或鼠标停在顶栏热区
    private enum PeekReason { case option, bar }
    private var peekReason: PeekReason?
    private var isPeeking: Bool { peekReason != nil }
    private var idleThrottled = false
    private var reconnectAttempt = 0
    private var reconnectWork: DispatchWorkItem?
    private var probeTimer: Timer?
    private var geometryRecheckWork: DispatchWorkItem?
    private var hiddenAutoCloseTimer: Timer?
    private var occlusionObserver: NSObjectProtocol?
    private var didExplainApplicationOnlyActivation = false
    /// 上次按需刷新标题的时刻，用于节流
    private var lastTitleRefresh: Date?
    /// 悬停上升沿判定（`HoverMonitor` 只在状态变化时回调，这里再收敛到「进入」这一个时机）
    private var wasHovering = false
    private var isClosed = false
    /// renderer 自愈触发的捕获流重启时刻，用于限流
    private var rendererRestartTimes: [TimeInterval] = []

    private static let hiddenAutoCloseSeconds: TimeInterval = 60
    private static let maxReconnectAttempts = 3
    /// 恢复后再确认一次几何的延时（要大于 `ShareableContentStore` 的 1 秒 TTL）
    private static let geometryRecheckDelay: TimeInterval = 1.2
    /// 标题按需刷新的最小间隔：挡住悬停抖动与菜单反复开合
    private static let titleRefreshThrottle: TimeInterval = 0.5
    /// renderer 自愈重启的限流窗口与窗口内上限
    private static let rendererRestartWindow: TimeInterval = 90
    private static let rendererRestartLimit = 2

    // MARK: - 生命周期

    init(request: SessionRequest, initialOrigin: CGPoint?, cascadeIndex: Int) {
        state = PiPSessionState(
            source: request.source,
            fps: request.fps,
            autoHide: request.autoHide,
            idleDetection: request.idleDetection
        )
        baseRect = request.baseSourceRect
        sourcePixelSize = request.sourcePixelSize
        positionIdentity = request.positionIdentity
        idleDetector = IdleDetector()

        let prefs = Preferences.shared
        let width = prefs.preferredWidth(for: request.source.preferenceKey)
            ?? min(max(request.sourcePointSize.width / 2, 320), 640)
        windowController = PiPWindowController(
            title: request.source.displayTitle,
            aspect: request.sourcePointSize,
            initialWidth: width,
            origin: initialOrigin,
            levelMode: prefs.windowLevelMode,
            cascadeIndex: cascadeIndex
        )

        super.init()

        windowController.delegate = self
        engine.delegate = self
        windowController.recordRendererEvent(
            "session.created id=\(id.uuidString.prefix(8)) source=\(request.source.displayTitle)"
        )
        windowController.show()
        windowController.update(state: state)
        registerHoverMonitor()
        observeOcclusion()
        startCapture()
    }

    deinit {
        if let occlusionObserver { NotificationCenter.default.removeObserver(occlusionObserver) }
    }

    func close() {
        guard !isClosed else { return }
        windowController.recordRendererEvent("session.close")
        isClosed = true
        reconnectWork?.cancel()
        geometryRecheckWork?.cancel()
        probeTimer?.invalidate()
        hiddenAutoCloseTimer?.invalidate()
        HoverMonitor.shared.unregister(id: id)
        engine.stop()
        persistGeometry()
        windowController.close()
        Log.info("会话关闭：\(state.source.displayTitle)")
        onClose?(self)
    }

    // MARK: - 对外操作

    var sourceWindowID: CGWindowID? { state.source.windowID }
    var positionFallbackPreferenceKey: String { positionIdentity.fallbackPreferenceKey }
    var title: String { state.source.displayTitle }
    var isHidden: Bool { state.isHidden }
    var isPaused: Bool { state.isPaused }

    func bringToFront() { windowController.bringToFront() }
    func flashHighlight() { windowController.flashHighlight() }

    /// ScreenCaptureKit 帧不携带窗口元数据，所以可变标题得单独取。
    ///
    /// 标题只在悬停浮出的顶栏与菜单里可见，因此**只在这些时机按需刷新**（见
    /// `refreshSourceTitleNow()`），不做常驻轮询：AX 是同步 IPC，常驻轮询既有稳态开销，
    /// 也会在源 App 卡死时拖住主线程。`CGWindowID` 身份始终不变。
    func refreshSourceTitle(_ title: String) {
        guard !isClosed,
              case let .window(windowID, bundleID, appName, oldTitle) = state.source else { return }
        let refreshed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !refreshed.isEmpty, refreshed != oldTitle else { return }
        state.source = .window(
            id: windowID, bundleID: bundleID, appName: appName, title: refreshed
        )
        windowController.setTitle(state.source.displayTitle)
        Log.debug("源窗口标题已更新：\(state.source.displayTitle)")
    }

    /// 按需刷新标题：鼠标进入浮窗、浮窗右键菜单更新、菜单栏菜单打开时各调用一次。
    func refreshSourceTitleNow() {
        guard !isClosed, let windowID = state.source.windowID else { return }
        if let last = lastTitleRefresh,
           Date().timeIntervalSince(last) < Self.titleRefreshThrottle { return }
        lastTitleRefresh = Date()
        guard let title = SourceWindowActivator.currentTitle(of: windowID) else { return }
        refreshSourceTitle(title)
    }

    /// 仅用于 `--smoke` 集成自检的调试信息
    var debugWindowFrame: CGRect { windowController.window.frame }
    var debugAlpha: CGFloat { windowController.window.alphaValue }
    var debugClickThrough: Bool { windowController.window.ignoresMouseEvents }
    var debugAutoHideActive: Bool { isAutoHidden }
    var debugPeeking: Bool { isPeeking }
    var debugBarScreenFrame: CGRect? { windowController.barScreenFrame }
    /// 仅用于 `--smoke-mc`：捕获基准矩形与实际下发的裁剪框
    var debugBaseRect: CGRect { baseRect }
    var debugSourceRect: CGRect { currentSourceRect() }
    /// 仅用于 `--smoke-mc`：立即跑一次源窗口探测（平时由卡流检测驱动）
    func debugProbeNow() { probeSource() }
    /// 仅用于 `--smoke-renderer`：入队/丢帧计数与手动触发一次计划性 flush
    var debugEnqueuedFrameCount: UInt64 { windowController.debugEnqueuedFrameCount }
    var debugNotReadyDropCount: UInt64 { windowController.debugNotReadyDropCount }
    func debugForceDiscontinuity(_ reason: String) {
        windowController.prepareForCaptureDiscontinuity(reason)
    }
    /// 仅用于 `--smoke-level`：浮窗与提示条子窗口的实际层级
    var debugWindowLevel: Int { windowController.debugWindowLevel }
    var debugHintWindowLevel: Int { windowController.debugHintWindowLevel }

    func setLevelMode(_ mode: WindowLevelMode) { windowController.setLevelMode(mode) }

    func setPaused(_ paused: Bool) {
        guard state.isPaused != paused else { return }
        state.isPaused = paused
        if paused {
            pauseCapture(reason: "用户暂停")
            update(runtimeState: .paused)
        } else {
            resumeCapture(reason: "暂停后恢复")
            update(runtimeState: .streaming)
        }
        windowController.update(state: state)
    }

    func setFPS(_ fps: FPSStep) {
        state.fps = fps
        Preferences.shared.setFPS(fps, for: state.source.preferenceKey)
        idleThrottled = false
        idleDetector.reset()
        retune(reason: "切换帧率到 \(fps.rawValue)fps")
        windowController.update(state: state)
    }

    /// 全局透明度偏好被别处改动（设置页）时调用：只对正处于淡出态的浮窗立即生效，不弹提示。
    func refreshAutoHideOpacity() {
        guard !isClosed, isAutoHidden, !isPeeking else { return }
        windowController.setAlpha(Preferences.shared.autoHideOpacity, animated: true)
    }

    func applyZoom(_ zoom: CGFloat, anchor: CGPoint) {
        let z = Geo.clampZoom(zoom)
        state.zoom = z
        state.anchor = Geo.clampAnchor(anchor, zoom: z)
        retune(reason: "画面缩放到 \(String(format: "%.3f", z))x")
        windowController.update(state: state)
    }

    func resetZoom() {
        state.zoom = 1
        state.anchor = CGPoint(x: 0.5, y: 0.5)
        retune(reason: "重置画面缩放")
        windowController.update(state: state)
    }

    func toggleIdleDetection() {
        state.idleDetection.toggle()
        idleDetector.reset()
        if !state.idleDetection, idleThrottled {
            idleThrottled = false
            retune(reason: "关闭静止检测并恢复帧率")
        }
        windowController.update(state: state)
    }

    func toggleAutoHide() {
        state.autoHide.toggle()
        windowController.update(state: state)

        guard state.autoHide else {
            endAutoHide()
            return
        }

        // 用户是点浮窗上的按钮开启的，此刻鼠标正在浮窗上：先把玩法讲清楚，
        // 3 秒后再真正淡出，否则用户会直接掉进「淡出 + 点击穿透」里找不到出口。
        windowController.showHint(
            L.t("鼠标移入将淡出；按住 ⌥ 可临时唤回，也可从菜单栏关闭",
                "Fades out on hover — hold ⌥ to peek, or turn it off from the menu bar"),
            near: nil, duration: 3.0
        )
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            guard let self, !self.isClosed, self.state.autoHide, !self.state.isHidden,
                  HoverMonitor.shared.currentHovered() == self.id,
                  !NSEvent.modifierFlags.contains(.option) else { return }
            self.beginAutoHide()
        }
    }

    /// 修改全局「自动隐藏透明度」（5% 一档），当前处于淡出态时立即生效。
    func setAutoHideOpacity(_ opacity: CGFloat) {
        let value = Preferences.clampOpacity(opacity)
        Preferences.shared.autoHideOpacity = value
        if isAutoHidden, !isPeeking {
            windowController.setAlpha(value, animated: true)
        }
        windowController.showHint(
            L.t("自动隐藏透明度 \(Preferences.opacityLabel(value))",
                "Auto-hide opacity \(Preferences.opacityLabel(value))"),
            near: nil, duration: 1.5
        )
        windowController.update(state: state)
    }

    func toggleHidden() {
        if state.isHidden { restoreFromHidden() } else { hideCompletely() }
    }

    /// 增强模式的悬停按键
    func applyHoverKey(_ key: EventTapManager.HoverKey) {
        switch key {
        case .zoomIn: applyZoom(state.zoom * 1.25, anchor: state.anchor)
        case .zoomOut: applyZoom(state.zoom / 1.25, anchor: state.anchor)
        case .cycleFPS: setFPS(state.fps.next())
        case .toggleIdleDetection: toggleIdleDetection()
        case .toggleHidden: toggleHidden()
        case .close: close()
        }
    }

    // MARK: - 完全隐藏

    private func hideCompletely() {
        state.isHidden = true
        pauseCapture(reason: "完全隐藏")
        windowController.hideCompletely()
        hiddenAutoCloseTimer?.invalidate()
        hiddenAutoCloseTimer = Timer.scheduledTimer(
            withTimeInterval: Self.hiddenAutoCloseSeconds, repeats: false
        ) { [weak self] _ in
            Log.debug("隐藏超时，自动关闭会话")
            self?.close()
        }
        windowController.update(state: state)
    }

    private func restoreFromHidden() {
        state.isHidden = false
        hiddenAutoCloseTimer?.invalidate()
        hiddenAutoCloseTimer = nil
        windowController.restoreFromHidden()
        if !state.isPaused { resumeCapture(reason: "完全隐藏后恢复") }
        windowController.update(state: state)
    }

    // MARK: - 捕获

    private func currentSourceRect() -> CGRect {
        // 整窗 + 未放大时不下发裁剪框：`.zero` 让 SCK 直接给整个窗口内容。
        // 这样即使 baseRect 没能及时跟上窗口尺寸（例如调度中心期间采样到被总览变换的
        // 矩形），画面也只是宽高比暂时不准，不会被裁成窗口左上角局部。
        if case .window = state.source,
           state.zoom <= PiPSessionState.minZoom + 0.001,
           abs(baseRect.minX) < 0.5, abs(baseRect.minY) < 0.5 {
            return .zero
        }
        return Geo.sourceRect(zoom: state.zoom, anchor: state.anchor, full: baseRect)
    }

    private func makeConfiguration(fps: Int? = nil) -> SCStreamConfiguration {
        CaptureEngine.makeConfiguration(
            sourceRect: currentSourceRect(),
            pointSize: windowController.contentPointSize,
            scale: windowController.backingScale,
            fps: fps ?? effectiveFPS,
            showsCursor: Preferences.shared.showsCursor
        )
    }

    private var effectiveFPS: Int {
        idleThrottled ? 1 : state.fps.rawValue
    }

    private func configurationSummary(_ configuration: SCStreamConfiguration) -> String {
        let rect = configuration.sourceRect
        let crop = rect.isEmpty ? "full" : String(
            format: "%.0f,%.0f %.0fx%.0f",
            rect.minX, rect.minY, rect.width, rect.height
        )
        return "output=\(configuration.width)x\(configuration.height) fps=\(CaptureEngine.fps(of: configuration)) crop=\(crop) backingScale=\(windowController.backingScale)"
    }

    private func retune(reason: String) {
        guard engine.isRunning else { return }
        let configuration = makeConfiguration()
        windowController.recordRendererEvent(
            "capture.retune reason=\(reason) \(configurationSummary(configuration))"
        )
        engine.retune(configuration)
    }

    private func pauseCapture(reason: String) {
        guard engine.isRunning, !engine.isPaused else { return }
        windowController.recordRendererEvent("capture.pause reason=\(reason)")
        engine.pause()
    }

    /// 恢复流前先清理 renderer 的旧队列；只在 engine 确实处于暂停态时执行。
    private func resumeCapture(reason: String) {
        guard engine.isPaused else { return }
        windowController.recordRendererEvent("capture.resume reason=\(reason)")
        windowController.prepareForCaptureDiscontinuity(reason)
        engine.resume()
    }

    private func restartCapture(reason: String) {
        windowController.recordRendererEvent("capture.restart.request reason=\(reason)")
        Log.debug("请求重启捕获流：\(reason)")
        engine.restart()
    }

    private func startCapture() {
        switch state.source {
        case let .window(windowID, _, _, _):
            ShareableContentStore.shared.window(id: windowID) { [weak self] window in
                guard let self, !self.isClosed else { return }
                guard let window else {
                    self.handleSourceMissing()
                    return
                }
                self.syncBaseRectIfNeeded(with: window)
                self.startStream(filter: CaptureEngine.filter(for: window))
            }
        case let .region(displayID, _):
            ShareableContentStore.shared.display(id: displayID) { [weak self] display in
                guard let self, !self.isClosed else { return }
                guard let display else {
                    self.handleSourceMissing()
                    return
                }
                let own = ShareableContentStore.shared.cachedOwnWindows
                self.startStream(filter: CaptureEngine.filter(forDisplay: display,
                                                             excludingOwnWindows: own))
            }
        }
    }

    private func startStream(filter: SCContentFilter) {
        let configuration = makeConfiguration()
        windowController.recordRendererEvent("capture.start \(configurationSummary(configuration))")
        do {
            try engine.start(filter: filter, configuration: configuration)
            reconnectAttempt = 0
            update(runtimeState: state.isPaused ? .paused : .streaming)
        } catch {
            Log.error("启动捕获失败：\(error.localizedDescription)")
            if !Permissions.hasScreenRecording {
                update(runtimeState: .permissionDenied)
            } else {
                update(runtimeState: .failed(message: error.localizedDescription))
                scheduleReconnect()
            }
        }
    }

    /// 整窗 PiP 时，窗口尺寸变化要同步基准矩形与宽高比。
    ///
    /// 只采纳「可信」的尺寸：调度中心 / Exposé 期间 `SCWindow.frame` 报的是被总览变换过的
    /// 矩形（且 `isOnScreen` 仍为 true），照抄会把裁剪框改小，退出总览后画面就永久停在
    /// 源窗口左上角局部。判定见 `Geo.trustedSourceSize`。
    private func syncBaseRectIfNeeded(with window: SCWindow) {
        guard case .window = state.source else { return }
        let isFullWindow = abs(baseRect.minX) < 0.5 && abs(baseRect.minY) < 0.5
        guard isFullWindow else { return }   // 窗口内的区域捕获不跟随窗口尺寸变化
        guard let size = trustedSize(of: window) else { return }
        guard abs(baseRect.width - size.width) > 1 || abs(baseRect.height - size.height) > 1 else { return }
        baseRect = CGRect(origin: .zero, size: size)
        let scale = ShareableContentStore.shared.backingScale(of: window)
        sourcePixelSize = CGSize(width: size.width * scale, height: size.height * scale)
        windowController.setAspect(size)
        state.anchor = Geo.clampAnchor(state.anchor, zoom: state.zoom)
    }

    /// 取当前可信的源窗口尺寸；判定为总览变换时返回 nil（保持原有几何）。
    private func trustedSize(of window: SCWindow) -> CGSize? {
        let size = Geo.trustedSourceSize(
            sampled: window.frame.size,
            current: baseRect,
            axSize: SourceWindowActivator.currentSize(of: window.windowID)
        )
        if size == nil {
            Log.debug("""
                跳过几何同步：窗口尺寸 \(Int(window.frame.width))×\(Int(window.frame.height)) \
                像是调度中心的总览变换
                """)
        }
        return size
    }

    /// 恢复后的一次性几何校正。
    ///
    /// 退出调度中心有 ~300ms 的动画中间态（实测会报出 1510×768 这类尺寸），
    /// 恢复瞬间的采样未必可信；延时超过 `ShareableContentStore` 的 1 秒 TTL 再确认一次，
    /// 顺带把历史遗留的错误几何自动纠正回来。
    private func scheduleGeometryRecheck() {
        guard case let .window(windowID, _, _, _) = state.source else { return }
        geometryRecheckWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.isClosed else { return }
            ShareableContentStore.shared.window(id: windowID) { [weak self] window in
                guard let self, !self.isClosed, let window else { return }
                let before = self.baseRect
                self.syncBaseRectIfNeeded(with: window)
                guard self.baseRect != before else { return }
                Log.debug("""
                    几何延时校正：\(Int(before.width))×\(Int(before.height)) → \
                    \(Int(self.baseRect.width))×\(Int(self.baseRect.height))
                    """)
                self.retune(reason: "源窗口几何延时校正")
            }
        }
        geometryRecheckWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.geometryRecheckDelay, execute: work)
    }

    // MARK: - CaptureEngineDelegate

    func captureWillRestart() {
        windowController.recordRendererEvent("capture.restart.begin")
        windowController.prepareForCaptureDiscontinuity("捕获流即将重建")
    }

    func captureDidOutput(_ sampleBuffer: CMSampleBuffer) {
        if state.idleDetection,
           let verdict = idleDetector.feed(sampleBuffer, activeFPS: state.fps.rawValue) {
            DispatchQueue.main.async { [weak self] in self?.apply(verdict) }
        }
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.isClosed else { return }
            if case .streaming = self.runtimeState {} else if !self.state.isPaused {
                self.update(runtimeState: .streaming)
                self.reconnectAttempt = 0
                self.probeTimer?.invalidate()
                self.probeTimer = nil
            }
            self.windowController.enqueue(sampleBuffer)
        }
    }

    func captureDidStop(error: Error?) {
        guard !isClosed else { return }
        guard let error else { return }   // 主动停止
        windowController.recordRendererEvent("capture.stop error=\(error.localizedDescription)")
        Log.warn("捕获中断：\(error.localizedDescription)")
        if !Permissions.hasScreenRecording {
            update(runtimeState: .permissionDenied)
            return
        }
        scheduleReconnect()
    }

    func captureDidStall() {
        guard !isClosed, !state.isPaused, !state.isHidden, !isAutoHidden else { return }
        windowController.recordRendererEvent("capture.stall no-valid-frame")
        // 没有新帧通常意味着源窗口被最小化或所在 Space 不可见
        update(runtimeState: .waitingForSource)
        startProbeTimer()
    }

    private func apply(_ verdict: IdleVerdict) {
        guard !isClosed, state.idleDetection else { return }
        guard verdict.isIdle != idleThrottled else { return }
        idleThrottled = verdict.isIdle
        Log.debug("静止检测：\(verdict.isIdle ? "降到 1fps" : "恢复 \(state.fps.rawValue)fps")")
        let configuration = makeConfiguration(fps: verdict.suggestedFPS)
        windowController.recordRendererEvent(
            "capture.retune reason=静止检测\(verdict.isIdle ? "降频" : "恢复") \(configurationSummary(configuration))"
        )
        engine.retune(configuration)
    }

    // MARK: - 断线恢复

    private func startProbeTimer() {
        guard probeTimer == nil else { return }
        probeTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.probeSource()
        }
    }

    private func probeSource() {
        guard !isClosed else { return }
        switch state.source {
        case let .window(windowID, _, _, _):
            ShareableContentStore.shared.window(id: windowID) { [weak self] window in
                guard let self, !self.isClosed else { return }
                if let window, window.isOnScreen {
                    Log.debug("源窗口已恢复，重启流")
                    self.probeTimer?.invalidate()
                    self.probeTimer = nil
                    self.syncBaseRectIfNeeded(with: window)
                    self.engine.retarget(CaptureEngine.filter(for: window))
                    self.restartCapture(reason: "源窗口恢复")
                    self.update(runtimeState: .streaming)
                    // 恢复瞬间可能落在退出总览的动画中间态，稍后再确认一次几何
                    self.scheduleGeometryRecheck()
                } else if window == nil {
                    self.attemptRematch()
                }
            }
        case .region:
            restartCapture(reason: "区域捕获恢复")
        }
    }

    private func scheduleReconnect() {
        guard !isClosed, reconnectAttempt < Self.maxReconnectAttempts else {
            attemptRematch()
            return
        }
        reconnectAttempt += 1
        let delay = pow(2.0, Double(reconnectAttempt - 1))   // 1s / 2s / 4s
        update(runtimeState: .reconnecting(attempt: reconnectAttempt))
        reconnectWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.isClosed else { return }
            Log.debug("第 \(self.reconnectAttempt) 次重连")
            self.windowController.recordRendererEvent(
                "capture.reconnect attempt=\(self.reconnectAttempt)"
            )
            self.windowController.prepareForCaptureDiscontinuity("捕获流重连")
            self.engine.stop()
            self.startCapture()
        }
        reconnectWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// 源窗口彻底消失后，尝试按 App + 标题重新匹配（App 退出后重开的场景）。
    private func attemptRematch() {
        guard case let .window(_, bundleID, appName, title) = state.source else {
            handleSourceMissing()
            return
        }
        ShareableContentStore.shared.rematch(bundleID: bundleID, appName: appName, title: title) {
            [weak self] window in
            guard let self, !self.isClosed else { return }
            guard let window else {
                self.handleSourceMissing()
                return
            }
            Log.info("已重新匹配到源窗口：\(ShareableContentStore.shared.displayTitle(for: window))")
            let rematchedSource = ShareableContentStore.shared.captureSource(for: window)
            self.state.source = rematchedSource
            self.positionIdentity = self.positionIdentity.retargetingWindow(to: rematchedSource)
            // 重新匹配同样不能照抄可能被总览变换过的尺寸
            let size = self.trustedSize(of: window) ?? self.baseRect.size
            self.baseRect = CGRect(origin: .zero, size: size)
            let scale = ShareableContentStore.shared.backingScale(of: window)
            self.sourcePixelSize = CGSize(width: size.width * scale, height: size.height * scale)
            self.windowController.setTitle(self.state.source.displayTitle)
            self.windowController.setAspect(size)
            self.probeTimer?.invalidate()
            self.probeTimer = nil
            self.reconnectAttempt = 0
            self.windowController.recordRendererEvent("capture.rematch source=\(self.state.source.displayTitle)")
            self.windowController.prepareForCaptureDiscontinuity("源窗口重新匹配")
            self.engine.stop()
            self.startStream(filter: CaptureEngine.filter(for: window))
        }
    }

    private func handleSourceMissing() {
        guard !isClosed else { return }
        windowController.recordRendererEvent("capture.source-missing")
        update(runtimeState: .sourceLost)
        engine.stop()
        probeTimer?.invalidate()
        probeTimer = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.close() }
    }

    private func update(runtimeState newState: SessionRuntimeState) {
        guard runtimeState != newState else { return }
        windowController.recordRendererEvent(
            "session.runtime \(String(describing: runtimeState)) -> \(String(describing: newState))"
        )
        runtimeState = newState
        windowController.update(runtimeState: newState)
    }

    // MARK: - 悬停 / 自动隐藏

    private func registerHoverMonitor() {
        HoverMonitor.shared.register(
            id: id,
            frameProvider: { [weak self] in
                guard let self, !self.isClosed, !self.state.isHidden else { return nil }
                return self.windowController.window.frame
            },
            hotZoneProvider: { [weak self] in
                // 顶栏热区：自动隐藏开启时，鼠标停在这里仍然可以操作与拖动
                guard let self, !self.isClosed, !self.state.isHidden else { return nil }
                return self.windowController.barScreenFrame
            },
            onChange: { [weak self] hover in
                self?.handleHover(hover)
            }
        )
    }

    /// 悬停状态处理。
    ///
    /// 自动隐藏开启后浮窗会淡出并点击穿透，此时它收不到任何鼠标事件——所以留了两条唤回通道：
    /// - **鼠标停在顶栏热区**：顶栏区域始终可操作（点按钮、按住拖动、右键），画面区域仍然穿透
    /// - **按住 ⌥**：在画面区域也能把整窗临时唤回
    /// 另有一条保底出口在菜单栏的每会话子菜单里。
    private func handleHover(_ hover: HoverState) {
        guard !isClosed else { return }

        // 顶栏一旦浮出就会显示源窗口标题，趁进入的这一刻按需刷新一次
        if hover.isHovering, !wasHovering { refreshSourceTitleNow() }
        wasHovering = hover.isHovering

        guard state.autoHide else {
            peekReason = nil
            windowController.setControlsVisible(hover.isHovering)
            return
        }

        guard hover.isHovering else {
            endAutoHide()
            return
        }

        if hover.isOverHotZone {
            beginPeek(.bar)           // 热区优先于 ⌥
        } else if hover.optionHeld {
            beginPeek(.option)
        } else {
            beginAutoHide()
        }
    }

    private func beginAutoHide() {
        guard !isAutoHidden || isPeeking else { return }
        isAutoHidden = true
        peekReason = nil
        windowController.showHint(nil, near: nil)
        windowController.setAlpha(Preferences.shared.autoHideOpacity, animated: true)
        windowController.setClickThrough(true)
        windowController.setControlsVisible(false)
        if !state.isPaused { pauseCapture(reason: "自动隐藏") }
    }

    /// 临时唤回：恢复不透明与可点击，让用户能点按钮、拖动窗口或调出右键菜单。
    private func beginPeek(_ reason: PeekReason) {
        guard peekReason != reason else { return }
        peekReason = reason
        isAutoHidden = true
        windowController.setAlpha(1, animated: true)
        windowController.setClickThrough(false)
        windowController.setControlsVisible(true)
        if !state.isPaused, !state.isHidden { resumeCapture(reason: "自动隐藏临时唤回") }
        switch reason {
        case .option:
            windowController.showHint(L.t("松开 ⌥ 恢复透明", "Release ⌥ to fade again"), near: nil)
        case .bar:
            windowController.showHint(L.t("移出顶栏后会重新淡出", "Leave the top bar to fade again"),
                                      near: nil, duration: 2.0)
        }
    }

    private func endAutoHide() {
        guard isAutoHidden || isPeeking else { return }
        isAutoHidden = false
        peekReason = nil
        windowController.showHint(nil, near: nil)
        windowController.setAlpha(1, animated: true)
        windowController.setClickThrough(false)
        windowController.setControlsVisible(false)
        if !state.isPaused, !state.isHidden { resumeCapture(reason: "自动隐藏结束") }
    }

    // MARK: - 遮挡时暂停

    private func observeOcclusion() {
        occlusionObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification,
            object: windowController.window,
            queue: .main
        ) { [weak self] _ in
            guard let self, !self.isClosed, !self.state.isPaused, !self.state.isHidden else { return }
            let visible = self.windowController.window.occlusionState.contains(.visible)
            if visible {
                self.resumeCapture(reason: "浮窗重新可见")
                // 遮挡期间（例如调度中心盖住浮窗）源窗口可能改过尺寸，恢复后确认一次
                self.scheduleGeometryRecheck()
            } else {
                // 浮窗被完全遮挡或所在 Space 不可见时没必要继续拉流
                self.pauseCapture(reason: "浮窗不可见")
            }
            Log.debug("浮窗可见性变化：\(visible ? "可见，恢复流" : "不可见，暂停流")")
        }
    }

    // MARK: - 屏幕参数变化

    func handleScreenParametersChanged() {
        guard !isClosed else { return }
        retune(reason: "屏幕参数变化")
    }

    private func persistGeometry() {
        Preferences.shared.setPreferredWidth(
            windowController.contentPointSize.width, for: state.source.preferenceKey
        )
        persistOrigin()
    }

    private func persistOrigin() {
        Preferences.shared.setOrigin(windowController.frameOrigin, for: positionIdentity)
    }

    // MARK: - PiPWindowDelegate

    var currentSessionState: PiPSessionState { state }

    func pipRequestClose() { close() }

    func pipRequestZoom(_ zoom: CGFloat, anchor: CGPoint) { applyZoom(zoom, anchor: anchor) }

    func pipRequestPan(by delta: CGSize) {
        guard state.zoom > 1.001 else { return }
        state.anchor = Geo.anchor(state.anchor, pannedBy: delta, zoom: state.zoom)
        retune(reason: "画面平移")
    }

    func pipRequestZoomReset() { resetZoom() }

    func pipDidResize(pointSize: CGSize, scale: CGFloat) {
        guard !isClosed else { return }
        Preferences.shared.setPreferredWidth(pointSize.width, for: state.source.preferenceKey)
        retune(reason: "浮窗尺寸变化 \(Int(pointSize.width))x\(Int(pointSize.height)) scale=\(scale)")
    }

    func pipRequestFPS(_ fps: FPSStep) { setFPS(fps) }

    func pipRequestToggleAutoHide() { toggleAutoHide() }

    func pipRequestAutoHideOpacity(_ opacity: CGFloat) { setAutoHideOpacity(opacity) }

    func pipRequestToggleIdleDetection() { toggleIdleDetection() }

    func pipRequestTogglePause() { setPaused(!state.isPaused) }

    /// renderer 永久损坏时，重启捕获流并不会救回来，而 `captureWillRestart` 又会重置卡流状态机，
    /// 于是「自愈耗尽 → 重启 → 再次耗尽」可以无限循环，每轮都重建一次 SCStream。这里限流：
    /// 窗口期内超过上限就停手并明确告知用户，成功恢复一次即清零。
    func pipRendererRecoveryExhausted() {
        guard !isClosed, !state.isPaused, !state.isHidden else { return }
        let now = ProcessInfo.processInfo.systemUptime
        rendererRestartTimes = rendererRestartTimes.filter { now - $0 < Self.rendererRestartWindow }
        guard rendererRestartTimes.count < Self.rendererRestartLimit else {
            Log.error("""
                renderer 自愈已达上限（\(Self.rendererRestartWindow)s 内 \
                \(Self.rendererRestartLimit) 次），停止自动重启：\(state.source.displayTitle)
                """)
            windowController.showHint(
                L.t("画面无法自动恢复，请关闭浮窗后重开",
                    "Could not recover automatically — close and reopen this PiP"),
                near: nil,
                duration: 6.0
            )
            return
        }
        rendererRestartTimes.append(now)
        Log.warn("显示层自愈失败，升级为重启捕获流：\(state.source.displayTitle)")
        restartCapture(reason: "renderer 自愈耗尽")
    }

    func pipRendererDidRecover() { rendererRestartTimes.removeAll() }

    func pipRequestActivateSource() { activateSource() }

    func pipRequestToggleClickToActivate() {
        Preferences.shared.clickToActivateSource.toggle()
        let on = Preferences.shared.clickToActivateSource
        windowController.showHint(
            on ? L.t("单击浮窗将切换到源窗口", "Click the PiP to switch to the source window")
               : L.t("已关闭「单击回源」", "Click-to-switch is off"),
            near: nil, duration: 2.0
        )
        windowController.update(state: state)
    }

    // MARK: - 单击回源

    /// 单击浮窗 → 切换到源应用窗口。
    ///
    /// 零权限路径只能激活「应用」；已授予辅助功能权限时按 `CGWindowID` 把具体窗口抬到最前。
    func activateSource() {
        guard !isClosed else { return }
        guard Preferences.shared.clickToActivateSource else {
            windowController.bringToFront()
            return
        }

        switch state.source {
        case let .window(windowID, bundleID, appName, title):
            var pid = ShareableContentStore.shared.cachedWindow(id: windowID)?
                .owningApplication?.processID
                ?? SourceWindowActivator.ownerPID(of: windowID)
            if pid == nil, let bundleID, !bundleID.isEmpty {
                pid = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
                    .first?.processIdentifier
            }
            guard let pid else {
                windowController.showHint(
                    L.t("源应用似乎已退出", "The source app seems to have quit"),
                    near: nil, duration: 2.0
                )
                return
            }
            switch SourceWindowActivator.activate(
                windowID: windowID, pid: pid, fallbackTitle: title
            ) {
            case .raised:
                Log.debug("单击回源：\(appName) [windowID=\(windowID)]")
            case .applicationOnly:
                if !didExplainApplicationOnlyActivation {
                    didExplainApplicationOnlyActivation = true
                    windowController.showHint(
                        L.t("授予辅助功能权限后可精确切换到这个窗口",
                            "Grant Accessibility to switch to this exact window"),
                        near: nil, duration: 3.0
                    )
                }
            case .windowNotFound:
                // 这一步其实已经激活了源应用，只是没能定位到具体窗口，别把话说成完全失败
                windowController.showHint(
                    L.t("已切换到源应用，但未能定位具体窗口",
                        "Switched to the source app, but could not locate the exact window"),
                    near: nil, duration: 2.0
                )
                Log.warn("单击回源未找到 AX 窗口：\(appName) [windowID=\(windowID)]")
            case .activationFailed:
                windowController.showHint(
                    L.t("无法切换到源窗口", "Could not activate the source window"),
                    near: nil, duration: 2.0
                )
            case .applicationNotFound:
                windowController.showHint(
                    L.t("源应用似乎已退出", "The source app seems to have quit"),
                    near: nil, duration: 2.0
                )
            }

        case .region:
            windowController.showHint(
                L.t("该浮窗来自屏幕区域，没有可切换的源应用",
                    "This PiP captures a screen region — no source app to switch to"),
                near: nil, duration: 2.0
            )
        }
    }

    func pipMenuWillOpen() { refreshSourceTitleNow() }

    func pipDidMove() {
        persistOrigin()
    }
}
