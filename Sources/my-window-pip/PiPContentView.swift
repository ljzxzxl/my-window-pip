import AVFoundation
import AppKit
import CoreMedia
import CoreVideo

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
    /// 拖动中的原始 frame → 经屏幕 / 其他 PiP 磁吸修正后的 frame。
    /// 最终只使用返回值的 origin，避免「移动」手势意外改变窗口尺寸。
    var onResolveDraggedWindowFrame: ((CGRect, NSEvent.ModifierFlags) -> CGRect)?
    /// renderer 经 flush + 重建 layer 后仍不恢复，交给会话层重启捕获流。
    var onRendererRecoveryExhausted: (() -> Void)?
    /// renderer 卡流恢复后，controller 用它显示一次非阻塞提示。
    var onRendererIncidentRecovered: ((String) -> Void)?
    /// 手动拖动窗口结束（本次按下确实移动过窗口）：上层据此确认跨屏 scale 变化
    var onDidDragWindow: (() -> Void)?
    /// 干净的单击（未拖动、`clickCount == 1`、无 Cmd/⌥/⌃/⇧）：请求切回源应用
    var onRequestActivateSource: (() -> Void)?

    // MARK: - 渲染

    private var displayLayer: AVSampleBufferDisplayLayer
    /// Cmd + 拖拽的框选提示层
    private let selectionLayer = CAShapeLayer()
    /// display layer 进入 failed 状态时只打一次日志，避免刷屏
    private var didLogRenderFailure = false
    /// 日志标签（源窗口标题），由 controller 注入。
    private var diagnosticLabel = "-"

    /// renderer 短暂 not-ready 很常见；连续 2 秒不接收才视为卡住。
    private static let rendererStallTimeout: TimeInterval = 2.0
    private var stallMonitor = RendererStallMonitor(timeout: rendererStallTimeout)
    private var flushToken = 0
    private var flushInFlightSince: TimeInterval?
    private var lastIncomingPTS: CMTime?
    private var lastPixelSize: CGSize?
    private var lastIncomingUptime: TimeInterval?
    private var lastEnqueuedUptime: TimeInterval?
    private var incomingFrameCount: UInt64 = 0
    private var enqueuedFrameCount: UInt64 = 0
    private var notReadyDropCount: UInt64 = 0
    private var rendererRecoveryCount: UInt64 = 0
    private var diagnostics = RendererDiagnostics()
    private var currentIncidentID: String?
    /// 第一次观测到 not-ready 的时间；跨 layer/捕获流重建也保持不变。
    private var currentIncidentStallStartedAt: TimeInterval?
    /// 从确认达到卡流阈值到恢复的时间；与从首次 not-ready 开始计算的卡流总时长分开。
    private var currentIncidentDetectedAt: TimeInterval?
    private var lastRendererStateSignature: String?

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
        displayLayer = Self.makeDisplayLayer()
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay

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

    private static func makeDisplayLayer() -> AVSampleBufferDisplayLayer {
        let layer = AVSampleBufferDisplayLayer()
        layer.videoGravity = .resizeAspect
        layer.backgroundColor = NSColor.black.cgColor
        return layer
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

    func setDiagnosticLabel(_ label: String) {
        let flattened = label.components(separatedBy: .newlines).joined(separator: " ")
        diagnosticLabel = flattened.isEmpty ? "-" : String(flattened.prefix(512))
        recordDiagnosticEvent("session.label \(diagnosticLabel)")
    }

    /// 捕获 / 会话层把低频生命周期事件写进同一个环形缓冲，供卡流快照关联。
    func recordDiagnosticEvent(_ event: String) {
        diagnostics.record(event, at: ProcessInfo.processInfo.systemUptime)
    }

    /// 仅用于 `--smoke-renderer`：验证计划性 flush 之后帧仍能继续入队。
    var debugEnqueuedFrameCount: UInt64 { enqueuedFrameCount }
    var debugNotReadyDropCount: UInt64 { notReadyDropCount }

    // MARK: - 帧入队

    /// 主线程调用。宁丢帧不积压：layer 不接收时直接丢弃当前帧。
    func enqueue(_ sampleBuffer: CMSampleBuffer) {
        guard CMSampleBufferIsValid(sampleBuffer) else { return }

        let now = ProcessInfo.processInfo.systemUptime
        incomingFrameCount &+= 1
        lastIncomingUptime = now
        let renderer = displayLayer.sampleBufferRenderer
        recordRendererTransition(renderer, at: now)

        // 新 SCStream / 输出分辨率变化可能带来格式或 PTS 时间线不连续。旧队列不能和
        // 新时间线混用，否则 AVFoundation 可能一直保留旧帧并把队列顶满。
        if let reason = incomingDiscontinuity(in: sampleBuffer) {
            diagnostics.record("frame.discontinuity \(reason)", at: now)
            var action = stallMonitor.requestImmediateFlush(at: now)
            // 恢复已经开始时不能反复从头计时，否则异常格式来回变化会阻止分级升级。
            if action == .none { action = stallMonitor.observeNotReady(at: now) }
            perform(action, at: now, reason: reason, planned: true)
            notReadyDropCount &+= 1
            return
        }

        // failed / requiresFlush 是明确错误，不等待卡流超时，立即 flush。
        if renderer.status == .failed || renderer.requiresFlushToResumeDecoding {
            if !didLogRenderFailure {
                didLogRenderFailure = true
                diagnostics.record("renderer.failure \(rendererState(renderer))", at: now)
                Log.warn("renderer 需要恢复 [\(diagnosticLabel)]：\(renderer.error?.localizedDescription ?? "-")")
            }
            var action = stallMonitor.requestImmediateFlush(at: now)
            if action == .none { action = stallMonitor.observeNotReady(at: now) }
            perform(action, at: now, reason: "renderer failed")
            notReadyDropCount &+= 1
            return
        }
        didLogRenderFailure = false

        // flush 尚未完成时不把新时间线的帧塞回旧队列；若 completion 丢失，状态机仍会
        // 在下一个 timeout 自动升级为重建 layer。
        if flushInFlightSince != nil {
            notReadyDropCount &+= 1
            let action = stallMonitor.observeNotReady(at: now)
            perform(action, at: now, reason: "flush 未完成")
            return
        }

        guard renderer.isReadyForMoreMediaData else {
            let wasTrackingStall = stallMonitor.isTrackingStall
            notReadyDropCount &+= 1
            let action = stallMonitor.observeNotReady(at: now)
            if !wasTrackingStall {
                diagnostics.record("renderer.not-ready.begin \(rendererState(renderer))", at: now)
                Log.debug("renderer 开始 not-ready [\(diagnosticLabel)]")
            }
            perform(action, at: now, reason: "持续 not-ready")
            return
        }

        if let stallDuration = stallMonitor.observeReady(at: now) {
            let message = "renderer 已恢复 [\(diagnosticLabel)]：not-ready \(String(format: "%.1f", stallDuration))s，累计丢帧 \(notReadyDropCount)"
            if stallDuration >= Self.rendererStallTimeout {
                Log.info(message)
            } else {
                Log.debug(message)
            }
            finishIncidentIfNeeded(at: now, stallDuration: stallDuration)
        }
        renderer.enqueue(sampleBuffer)
        enqueuedFrameCount &+= 1
        lastEnqueuedUptime = now
    }

    /// 捕获流即将 resume / restart：清掉旧队列但保留最后画面，下一帧自然接上。
    func prepareForCaptureDiscontinuity(_ reason: String) {
        let now = ProcessInfo.processInfo.systemUptime
        diagnostics.record("capture.discontinuity \(reason)", at: now)
        lastIncomingPTS = nil
        lastPixelSize = nil
        stallMonitor.reset()
        let action = stallMonitor.requestImmediateFlush(at: now)
        perform(action, at: now, reason: reason, planned: true)
    }

    /// 关闭 / 重连时清空 layer 与所有待处理手势。
    func flushAndReset() {
        let now = ProcessInfo.processInfo.systemUptime
        diagnostics.record("renderer.reset removing-image=true", at: now)
        if let id = currentIncidentID {
            Log.warn("renderer incident \(id) 未等到 ready，因会话 reset 结束 [\(diagnosticLabel)]")
            currentIncidentID = nil
            currentIncidentStallStartedAt = nil
            currentIncidentDetectedAt = nil
        }
        flushToken &+= 1
        flushInFlightSince = nil
        // SCK 输出的是未压缩 BGRA pixel buffer，每帧都可独立显示，满足 flush 后下一帧
        // 必须是 sync frame 的约定；不需要等待视频编码语义上的 IDR。
        displayLayer.sampleBufferRenderer.flush(
            removingDisplayedImage: true, completionHandler: nil
        )
        stallMonitor.reset()
        lastIncomingPTS = nil
        lastPixelSize = nil
        lastRendererStateSignature = nil
        cancelSelection()
        resetDragTracking()
        pendingPan = .zero
        pendingZoom = nil
        didLogRenderFailure = false
    }

    // MARK: - Renderer 健康与恢复

    private func incomingDiscontinuity(in sampleBuffer: CMSampleBuffer) -> String? {
        var reason: String?

        if let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
            let size = CGSize(width: CVPixelBufferGetWidth(pixelBuffer),
                              height: CVPixelBufferGetHeight(pixelBuffer))
            if let previous = lastPixelSize, previous != size {
                reason = "输出尺寸变化 \(Int(previous.width))×\(Int(previous.height)) → \(Int(size.width))×\(Int(size.height))"
            }
            lastPixelSize = size
        }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if pts.isValid {
            if let previous = lastIncomingPTS, previous.isValid, CMTimeCompare(pts, previous) < 0 {
                reason = "PTS 时间线回退"
            }
            lastIncomingPTS = pts
        }
        return reason
    }

    private func perform(_ action: RendererStallMonitor.RecoveryAction,
                         at now: TimeInterval, reason: String, planned: Bool = false) {
        guard action != .none else { return }
        let isPlannedFlush = planned && action == .flush
        if !isPlannedFlush { beginIncidentIfNeeded(at: now, trigger: reason) }

        switch action {
        case .none:
            return
        case .flush:
            beginRendererFlush(at: now, reason: reason, planned: planned)
        case .rebuildLayer:
            diagnostics.record("recovery.rebuild-layer reason=\(reason)", at: now)
            rebuildDisplayLayer(reason: reason)
        case .restartCapture:
            diagnostics.record("recovery.restart-capture reason=\(reason)", at: now)
            Log.error("renderer 自愈耗尽 [\(diagnosticLabel)]：请求重启捕获流（\(reason)）")
            onRendererRecoveryExhausted?()
        }
    }

    private func beginRendererFlush(at now: TimeInterval, reason: String, planned: Bool) {
        guard flushInFlightSince == nil else { return }
        flushToken &+= 1
        let token = flushToken
        flushInFlightSince = now
        diagnostics.record("recovery.flush.begin planned=\(planned) reason=\(reason)", at: now)
        if planned {
            Log.debug("renderer 时间线重置 [\(diagnosticLabel)]：\(reason)")
        } else {
            rendererRecoveryCount &+= 1
            Log.warn("renderer 卡流恢复 #\(rendererRecoveryCount) [\(diagnosticLabel)]：flush，原因=\(reason)，成功入队=\(enqueuedFrameCount)，not-ready 丢帧=\(notReadyDropCount)")
        }

        displayLayer.sampleBufferRenderer.flush(
            removingDisplayedImage: false
        ) { [weak self] in
            DispatchQueue.main.async {
                guard let self, self.flushToken == token else { return }
                let completedAt = ProcessInfo.processInfo.systemUptime
                self.diagnostics.record(
                    String(format: "recovery.flush.complete duration=%.3fs", completedAt - now),
                    at: completedAt
                )
                self.flushInFlightSince = nil
            }
        }
    }

    private func rebuildDisplayLayer(reason: String) {
        flushToken &+= 1                         // 让旧 flush completion 失效
        flushInFlightSince = nil
        rendererRecoveryCount &+= 1

        let old = displayLayer
        old.sampleBufferRenderer.flush(removingDisplayedImage: true, completionHandler: nil)
        old.removeFromSuperlayer()

        let replacement = Self.makeDisplayLayer()
        replacement.frame = bounds
        replacement.contentsScale = window?.backingScaleFactor ?? 2
        displayLayer = replacement

        if let root = layer {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            root.insertSublayer(replacement, at: 0)
            CATransaction.commit()
        }
        lastIncomingPTS = nil
        lastPixelSize = nil
        lastRendererStateSignature = nil
        Log.warn("renderer 卡流恢复 #\(rendererRecoveryCount) [\(diagnosticLabel)]：已重建 display layer，原因=\(reason)")
    }

    private func beginIncidentIfNeeded(at now: TimeInterval, trigger: String) {
        guard currentIncidentID == nil else { return }
        let id = "R-\(UUID().uuidString.prefix(8).uppercased())"
        currentIncidentID = id
        currentIncidentStallStartedAt = stallMonitor.stallStartedAt ?? now
        currentIncidentDetectedAt = now
        diagnostics.record("incident.begin id=\(id) trigger=\(trigger)", at: now)
        let report = diagnostics.incidentReport(
            id: id,
            label: diagnosticLabel,
            at: now,
            trigger: trigger,
            snapshot: rendererSnapshot(at: now)
        )
        Log.warn("\(report)\n  log file: \(Log.filePath)")
    }

    private func finishIncidentIfNeeded(at now: TimeInterval, stallDuration lastPhaseDuration: TimeInterval) {
        guard let id = currentIncidentID else { return }
        let timing = RendererIncidentTiming(
            stallStartedAt: currentIncidentStallStartedAt,
            detectedAt: currentIncidentDetectedAt,
            recoveredAt: now,
            lastPhaseDuration: lastPhaseDuration
        )
        diagnostics.record(
            String(
                format: "incident.recovered id=%@ stallDuration=%.3fs recoveryDuration=%.3fs",
                id, timing.stallDuration, timing.recoveryDuration
            ),
            at: now
        )
        Log.info(
            "renderer incident \(id) 已恢复 [\(diagnosticLabel)]：卡流总时长 "
                + "\(String(format: "%.3f", timing.stallDuration))s；自动恢复耗时 "
                + "\(String(format: "%.3f", timing.recoveryDuration))s；日志 \(Log.filePath)"
        )
        currentIncidentID = nil
        currentIncidentStallStartedAt = nil
        currentIncidentDetectedAt = nil
        onRendererIncidentRecovered?(id)
    }

    private func recordRendererTransition(_ renderer: AVSampleBufferVideoRenderer,
                                          at now: TimeInterval) {
        let signature = rendererState(renderer)
        guard signature != lastRendererStateSignature else { return }
        lastRendererStateSignature = signature
        diagnostics.record("renderer.state \(signature)", at: now)
    }

    private func rendererSnapshot(at now: TimeInterval) -> String {
        let renderer = displayLayer.sampleBufferRenderer
        let pixel = lastPixelSize.map { "\(Int($0.width))x\(Int($0.height))" } ?? "-"
        let pts: String
        if let lastIncomingPTS, lastIncomingPTS.isValid {
            pts = String(format: "%.6f", CMTimeGetSeconds(lastIncomingPTS))
        } else {
            pts = "-"
        }
        let flushAge = age(since: flushInFlightSince, now: now)
        return "\(rendererState(renderer)) incoming=\(incomingFrameCount) enqueued=\(enqueuedFrameCount) dropped=\(notReadyDropCount) lastIncomingAge=\(age(since: lastIncomingUptime, now: now)) lastEnqueuedAge=\(age(since: lastEnqueuedUptime, now: now)) flushAge=\(flushAge) pixel=\(pixel) pts=\(pts)"
    }

    private func rendererState(_ renderer: AVSampleBufferVideoRenderer) -> String {
        let status: String
        switch renderer.status {
        case .unknown: status = "unknown"
        case .rendering: status = "rendering"
        case .failed: status = "failed"
        @unknown default: status = "future(\(renderer.status.rawValue))"
        }
        let error = renderer.error.map { String(describing: $0) } ?? "-"
        return "status=\(status) ready=\(renderer.isReadyForMoreMediaData) requiresFlush=\(renderer.requiresFlushToResumeDecoding) error=\(error)"
    }

    private func age(since uptime: TimeInterval?, now: TimeInterval) -> String {
        guard let uptime else { return "-" }
        return String(format: "%.3fs", max(0, now - uptime))
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
        let resolved = onResolveDraggedWindowFrame?(frame, event.modifierFlags) ?? frame
        frame.origin = resolved.origin
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
