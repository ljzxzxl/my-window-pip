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

    private let engine = CaptureEngine()
    private let windowController: PiPWindowController
    private let idleDetector: IdleDetector

    /// 关闭回调（由 SessionStore 注入）
    var onClose: ((PiPSession) -> Void)?

    // 运行期辅助状态
    private var isAutoHidden = false
    private var idleThrottled = false
    private var reconnectAttempt = 0
    private var reconnectWork: DispatchWorkItem?
    private var probeTimer: Timer?
    private var hiddenAutoCloseTimer: Timer?
    private var occlusionObserver: NSObjectProtocol?
    private var isClosed = false

    private static let hiddenAutoCloseSeconds: TimeInterval = 60
    private static let maxReconnectAttempts = 3

    // MARK: - 生命周期

    init(request: SessionRequest, cascadeIndex: Int) {
        state = PiPSessionState(
            source: request.source,
            fps: request.fps,
            autoHide: request.autoHide,
            idleDetection: request.idleDetection
        )
        baseRect = request.baseSourceRect
        sourcePixelSize = request.sourcePixelSize
        idleDetector = IdleDetector()

        let prefs = Preferences.shared
        let width = prefs.preferredWidth(for: request.source.preferenceKey)
            ?? min(max(request.sourcePointSize.width / 2, 320), 640)
        windowController = PiPWindowController(
            title: request.source.displayTitle,
            aspect: request.sourcePointSize,
            initialWidth: width,
            origin: prefs.origin(for: request.source.preferenceKey),
            levelMode: prefs.windowLevelMode,
            cascadeIndex: cascadeIndex
        )

        super.init()

        windowController.delegate = self
        engine.delegate = self
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
        isClosed = true
        reconnectWork?.cancel()
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
    var title: String { state.source.displayTitle }
    var isHidden: Bool { state.isHidden }
    var isPaused: Bool { state.isPaused }

    func bringToFront() { windowController.bringToFront() }
    func flashHighlight() { windowController.flashHighlight() }

    /// 仅用于 `--smoke` 集成自检的调试信息
    var debugWindowFrame: CGRect { windowController.window.frame }

    func setLevelMode(_ mode: WindowLevelMode) { windowController.setLevelMode(mode) }

    func setPaused(_ paused: Bool) {
        guard state.isPaused != paused else { return }
        state.isPaused = paused
        if paused {
            engine.pause()
            update(runtimeState: .paused)
        } else {
            engine.resume()
            update(runtimeState: .streaming)
        }
        windowController.update(state: state)
    }

    func setFPS(_ fps: FPSStep) {
        state.fps = fps
        Preferences.shared.setFPS(fps, for: state.source.preferenceKey)
        idleThrottled = false
        idleDetector.reset()
        retune()
        windowController.update(state: state)
    }

    func applyZoom(_ zoom: CGFloat, anchor: CGPoint) {
        let z = Geo.clampZoom(zoom)
        state.zoom = z
        state.anchor = Geo.clampAnchor(anchor, zoom: z)
        retune()
        windowController.update(state: state)
    }

    func resetZoom() {
        state.zoom = 1
        state.anchor = CGPoint(x: 0.5, y: 0.5)
        retune()
        windowController.update(state: state)
    }

    func toggleIdleDetection() {
        state.idleDetection.toggle()
        idleDetector.reset()
        if !state.idleDetection, idleThrottled {
            idleThrottled = false
            retune()
        }
        windowController.update(state: state)
    }

    func toggleAutoHide() {
        state.autoHide.toggle()
        if !state.autoHide, isAutoHidden { endAutoHide() }
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
        engine.pause()
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
        if !state.isPaused { engine.resume() }
        windowController.update(state: state)
    }

    // MARK: - 捕获

    private func currentSourceRect() -> CGRect {
        Geo.sourceRect(zoom: state.zoom, anchor: state.anchor, full: baseRect)
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

    private func retune() {
        guard engine.isRunning else { return }
        engine.retune(makeConfiguration())
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
        do {
            try engine.start(filter: filter, configuration: makeConfiguration())
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
    private func syncBaseRectIfNeeded(with window: SCWindow) {
        guard case .window = state.source else { return }
        let size = window.frame.size
        guard size.width > 1, size.height > 1 else { return }
        let isFullWindow = abs(baseRect.minX) < 0.5 && abs(baseRect.minY) < 0.5
        guard isFullWindow else { return }   // 窗口内的区域捕获不跟随窗口尺寸变化
        guard abs(baseRect.width - size.width) > 1 || abs(baseRect.height - size.height) > 1 else { return }
        baseRect = CGRect(origin: .zero, size: size)
        sourcePixelSize = ShareableContentStore.shared.pixelSize(of: window)
        windowController.setAspect(size)
        state.anchor = Geo.clampAnchor(state.anchor, zoom: state.zoom)
    }

    // MARK: - CaptureEngineDelegate

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
        Log.warn("捕获中断：\(error.localizedDescription)")
        if !Permissions.hasScreenRecording {
            update(runtimeState: .permissionDenied)
            return
        }
        scheduleReconnect()
    }

    func captureDidStall() {
        guard !isClosed, !state.isPaused, !state.isHidden, !isAutoHidden else { return }
        // 没有新帧通常意味着源窗口被最小化或所在 Space 不可见
        update(runtimeState: .waitingForSource)
        startProbeTimer()
    }

    private func apply(_ verdict: IdleVerdict) {
        guard !isClosed, state.idleDetection else { return }
        guard verdict.isIdle != idleThrottled else { return }
        idleThrottled = verdict.isIdle
        Log.debug("静止检测：\(verdict.isIdle ? "降到 1fps" : "恢复 \(state.fps.rawValue)fps")")
        engine.retune(makeConfiguration(fps: verdict.suggestedFPS))
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
                    self.engine.restart()
                    self.update(runtimeState: .streaming)
                } else if window == nil {
                    self.attemptRematch()
                }
            }
        case .region:
            engine.restart()
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
            self.state.source = ShareableContentStore.shared.captureSource(for: window)
            self.baseRect = CGRect(origin: .zero, size: window.frame.size)
            self.sourcePixelSize = ShareableContentStore.shared.pixelSize(of: window)
            self.windowController.setTitle(self.state.source.displayTitle)
            self.windowController.setAspect(window.frame.size)
            self.probeTimer?.invalidate()
            self.probeTimer = nil
            self.reconnectAttempt = 0
            self.engine.stop()
            self.startStream(filter: CaptureEngine.filter(for: window))
        }
    }

    private func handleSourceMissing() {
        guard !isClosed else { return }
        update(runtimeState: .sourceLost)
        engine.stop()
        probeTimer?.invalidate()
        probeTimer = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.close() }
    }

    private func update(runtimeState newState: SessionRuntimeState) {
        guard runtimeState != newState else { return }
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
            onChange: { [weak self] hovering in
                self?.setHovering(hovering)
            }
        )
    }

    private func setHovering(_ hovering: Bool) {
        guard !isClosed else { return }
        if state.autoHide {
            if hovering { beginAutoHide() } else { endAutoHide() }
        } else {
            windowController.setControlsVisible(hovering)
        }
    }

    private func beginAutoHide() {
        guard !isAutoHidden else { return }
        isAutoHidden = true
        windowController.setAlpha(0.08, animated: true)
        windowController.setClickThrough(true)
        windowController.setControlsVisible(false)
        if !state.isPaused { engine.pause() }
    }

    private func endAutoHide() {
        guard isAutoHidden else { return }
        isAutoHidden = false
        windowController.setAlpha(1, animated: true)
        windowController.setClickThrough(false)
        if !state.isPaused, !state.isHidden { engine.resume() }
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
                self.engine.resume()
            } else {
                // 浮窗被完全遮挡或所在 Space 不可见时没必要继续拉流
                self.engine.pause()
            }
            Log.debug("浮窗可见性变化：\(visible ? "可见，恢复流" : "不可见，暂停流")")
        }
    }

    // MARK: - 屏幕参数变化

    func handleScreenParametersChanged() {
        guard !isClosed else { return }
        retune()
    }

    private func persistGeometry() {
        let key = state.source.preferenceKey
        Preferences.shared.setPreferredWidth(windowController.contentPointSize.width, for: key)
        Preferences.shared.setOrigin(windowController.frameOrigin, for: key)
    }

    // MARK: - PiPWindowDelegate

    var currentSessionState: PiPSessionState { state }

    func pipRequestClose() { close() }

    func pipRequestZoom(_ zoom: CGFloat, anchor: CGPoint) { applyZoom(zoom, anchor: anchor) }

    func pipRequestPan(by delta: CGSize) {
        guard state.zoom > 1.001 else { return }
        state.anchor = Geo.anchor(state.anchor, pannedBy: delta, zoom: state.zoom)
        retune()
    }

    func pipRequestZoomReset() { resetZoom() }

    func pipDidResize(pointSize: CGSize, scale: CGFloat) {
        guard !isClosed else { return }
        Preferences.shared.setPreferredWidth(pointSize.width, for: state.source.preferenceKey)
        retune()
    }

    func pipRequestFPS(_ fps: FPSStep) { setFPS(fps) }

    func pipRequestToggleAutoHide() { toggleAutoHide() }

    func pipRequestToggleIdleDetection() { toggleIdleDetection() }

    func pipRequestTogglePause() { setPaused(!state.isPaused) }

    func pipDidMove() {
        Preferences.shared.setOrigin(windowController.frameOrigin, for: state.source.preferenceKey)
    }
}
