import AppKit
import CoreGraphics
import CoreMedia
import CoreVideo
import ScreenCaptureKit

/// 单路 `SCStream` 的封装：一个 PiP 会话一个实例。
///
/// 职责边界：
/// - 只管「流的生命周期 + 参数下发 + 帧闸门」，不做 UI、不做错误重试策略
///   （重试与占位提示由会话层 `PiPSession` 负责，本类只提供可反复安全调用的 `restart()`）。
/// - 帧回调在专用串行队列上派发给 delegate，绝不在回调里做 UI。
/// - 不持有 `CMSampleBuffer` 跨帧，也不缓存历史帧。
///
/// 线程约定：`start` 必须在主线程调用；其余方法在任意线程调用都安全（内部自动切主线程），
/// 因此会话层可以直接在捕获队列里根据 `IdleVerdict` 调 `retune`。
final class CaptureEngine: NSObject, SCStreamOutput, SCStreamDelegate {

    // MARK: - 常量

    /// 帧回调队列标签
    static let queueLabel = "com.ljzxzxl.mywindowpip.capture"
    /// `retune` 节流窗口：拖拽缩放时高频调用合并为末次生效
    private static let retuneThrottle: TimeInterval = 0.1
    /// `restart` 合并窗口：极短时间内的重复重建请求只做一次（配置/过滤器都取最新值，不会丢状态）
    private static let restartCoalesce: TimeInterval = 0.3
    /// 输出像素上限（与 `Geo.pixelSize` 保持一致）
    static let maxOutputPixels = 4096

    // MARK: - 对外状态

    weak var delegate: CaptureEngineDelegate?

    /// 当前实际生效的帧率（由配置的 `minimumFrameInterval` 反推）
    private(set) var currentFPS: Int = FPSStep.fifteen.rawValue
    /// 是否有活动的流
    private(set) var isRunning = false
    /// 是否处于「暂停」（流已停但保留了 filter/config，可 `resume`）
    private(set) var isPaused = false

    // MARK: - 内部状态（只在主线程读写）

    private var stream: SCStream?
    private var filter: SCContentFilter?
    private var configuration: SCStreamConfiguration?

    private var pendingConfiguration: SCStreamConfiguration?
    private var retuneFlushScheduled = false
    private var lastRetuneUptime: TimeInterval = -.greatestFiniteMagnitude
    private var lastRestartUptime: TimeInterval = -.greatestFiniteMagnitude
    /// 帧回调队列：串行 + userInitiated，保证帧顺序且不与 UI 抢主线程
    private let frameQueue = DispatchQueue(label: CaptureEngine.queueLabel, qos: .userInitiated)

    // MARK: - 卡流检测状态（跨线程，用锁保护）

    private let stallLock = NSLock()
    private var lastFrameUptime: TimeInterval = 0
    private var stallReported = false
    private var stallTimer: DispatchSourceTimer?

    // MARK: - 生命周期

    override init() {
        super.init()
    }

    deinit {
        stallTimer?.cancel()
        stallTimer = nil
        // 注意：deinit 里不要把 self 再交给 SCStream（removeStreamOutput），只停流即可
        stream?.stopCapture { _ in }
        stream = nil
    }

    // MARK: - 过滤器 / 配置构造

    /// 单窗口过滤器：跟随窗口移动，窗口被遮挡也能捕获。
    static func filter(for window: SCWindow) -> SCContentFilter {
        SCContentFilter(desktopIndependentWindow: window)
    }

    /// 显示器过滤器（区域捕获用）。必须排除自身 App，否则 PiP 浮窗会把自己拍进去形成镜中镜。
    ///
    /// 优先按「App」排除而非按「窗口」排除：新建的浮窗可能还没出现在窗口枚举缓存里，
    /// 按 App 排除能覆盖这种时序空窗；拿不到 `SCRunningApplication` 时退回按窗口排除。
    static func filter(forDisplay display: SCDisplay,
                       excludingOwnWindows ownWindows: [SCWindow]) -> SCContentFilter {
        var apps: [SCRunningApplication] = []
        for window in ownWindows {
            guard let app = window.owningApplication else { continue }
            if !apps.contains(where: { $0.processID == app.processID }) { apps.append(app) }
        }
        if !apps.isEmpty {
            return SCContentFilter(display: display, excludingApplications: apps, exceptingWindows: [])
        }
        return SCContentFilter(display: display, excludingWindows: ownWindows)
    }

    /// 生成流配置。
    /// - Parameters:
    ///   - sourceRect: 源坐标系裁剪矩形（左上原点、逻辑点）；空矩形表示捕获完整内容
    ///   - pointSize: 浮窗内容的逻辑尺寸（点）
    ///   - scale: 浮窗所在屏幕的 backingScaleFactor
    ///   - fps: 目标帧率（clamp 到 1…60）
    ///   - showsCursor: 是否把鼠标指针画进画面
    static func makeConfiguration(sourceRect: CGRect, pointSize: CGSize, scale: CGFloat,
                                  fps: Int, showsCursor: Bool) -> SCStreamConfiguration {
        let cfg = SCStreamConfiguration()
        cfg.sourceRect = sanitizedSourceRect(sourceRect)     // 服务端裁剪，放大后仍是原生像素
        let px = Geo.pixelSize(points: pointSize, scale: max(1, scale))
        cfg.width = px.width
        cfg.height = px.height
        let clampedFPS = min(max(fps, 1), 60)
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(clampedFPS))
        cfg.pixelFormat = kCVPixelFormatType_32BGRA          // 与 FrameGate 的指纹算法一致
        cfg.colorSpaceName = CGColorSpace.sRGB
        cfg.queueDepth = 3                                   // 低帧率下不需要大缓冲，省内存
        cfg.scalesToFit = true
        cfg.showsCursor = showsCursor
        cfg.capturesAudio = false                            // v2 预留：音频跟随
        // 单窗口捕获默认会带上窗口阴影，浮窗里会显示成一圈半透明边，去掉更干净
        cfg.ignoreShadowsSingleWindow = true
        if #available(macOS 14.2, *) {
            cfg.includeChildWindows = true                   // 抽屉/弹出面板也一起进画面
        }
        return cfg
    }

    /// 从配置反推帧率（`minimumFrameInterval` → fps），非法值按 60 处理。
    static func fps(of configuration: SCStreamConfiguration) -> Int {
        let seconds = CMTimeGetSeconds(configuration.minimumFrameInterval)
        guard seconds.isFinite, seconds > 0 else { return FPSStep.sixty.rawValue }
        return min(max(Int((1.0 / seconds).rounded()), 1), 60)
    }

    /// 裁剪矩形规范化：非法值退化为「完整内容」，并对齐到整点减少重采样模糊。
    private static func sanitizedSourceRect(_ rect: CGRect) -> CGRect {
        guard rect.minX.isFinite, rect.minY.isFinite, rect.width.isFinite, rect.height.isFinite,
              rect.width >= 1, rect.height >= 1 else { return .zero }
        return CGRect(x: rect.minX.rounded(), y: rect.minY.rounded(),
                      width: rect.width.rounded(), height: rect.height.rounded())
    }

    // MARK: - 启停

    /// 启动流。必须在主线程调用（会话创建流程本身就在主线程）。
    /// 反复调用安全：内部先拆掉旧流再建新流。
    func start(filter: SCContentFilter, configuration: SCStreamConfiguration) throws {
        tearDownStream()
        self.filter = filter
        self.configuration = configuration
        currentFPS = Self.fps(of: configuration)

        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: frameQueue)
        self.stream = stream
        isRunning = true
        isPaused = false
        startStallWatchdog()

        stream.startCapture { [weak self] error in
            guard let error else { return }
            DispatchQueue.main.async {
                guard let self, self.stream === stream else { return }   // 旧流的迟到回调忽略
                Log.error("启动捕获失败：\(error.localizedDescription)")
                self.tearDownStream()
                self.delegate?.captureDidStop(error: error)
            }
        }
        Log.debug("捕获已启动：\(configuration.width)×\(configuration.height) @ \(currentFPS)fps")
    }

    /// 彻底停止（不再回调 delegate）。保留 filter/config，`restart()` 仍可用。
    func stop() {
        onMain { [weak self] in
            guard let self else { return }
            self.pendingConfiguration = nil
            self.tearDownStream()
            self.isPaused = false
        }
    }

    /// 暂停：停流但保留 filter/config，供 `resume()` 原样恢复。
    func pause() {
        onMain { [weak self] in
            guard let self, self.isRunning, !self.isPaused else { return }
            self.tearDownStream()
            self.isPaused = true
            Log.debug("捕获已暂停")
        }
    }

    /// 从暂停恢复。
    func resume() {
        onMain { [weak self] in
            guard let self, self.isPaused else { return }
            self.isPaused = false
            guard let filter = self.filter, let configuration = self.configuration else { return }
            do {
                try self.start(filter: filter, configuration: configuration)
                Log.debug("捕获已恢复")
            } catch {
                Log.error("恢复捕获失败：\(error.localizedDescription)")
                self.delegate?.captureDidStop(error: error)
            }
        }
    }

    // MARK: - 参数更新

    /// 更新配置（`SCStream.updateConfiguration`，不重建流所以无黑帧）。
    /// 内部 100ms 节流合并：首次立即生效，窗口期内的连续调用只保留末次。
    func retune(_ configuration: SCStreamConfiguration) {
        onMain { [weak self] in
            guard let self else { return }
            // 先记住最新配置：resume/restart 都以它为准
            self.configuration = configuration
            self.currentFPS = Self.fps(of: configuration)

            let now = ProcessInfo.processInfo.systemUptime
            if !self.retuneFlushScheduled, now - self.lastRetuneUptime >= Self.retuneThrottle {
                self.lastRetuneUptime = now
                self.pendingConfiguration = nil
                self.applyConfiguration(configuration)
                return
            }
            self.pendingConfiguration = configuration
            guard !self.retuneFlushScheduled else { return }
            self.retuneFlushScheduled = true
            let delay = max(0, Self.retuneThrottle - (now - self.lastRetuneUptime))
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self else { return }
                self.retuneFlushScheduled = false
                guard let pending = self.pendingConfiguration else { return }
                self.pendingConfiguration = nil
                self.lastRetuneUptime = ProcessInfo.processInfo.systemUptime
                self.applyConfiguration(pending)
            }
        }
    }

    /// 更换捕获目标（`SCStream.updateContentFilter`），用于源窗口重连 / 区域改窗口。
    func retarget(_ filter: SCContentFilter) {
        onMain { [weak self] in
            guard let self else { return }
            self.filter = filter
            guard let stream = self.stream else { return }
            stream.updateContentFilter(filter) { [weak self] error in
                guard let error else { return }
                Log.warn("updateContentFilter 失败：\(error.localizedDescription)，改为重建流")
                DispatchQueue.main.async { self?.restart() }
            }
        }
    }

    /// 兜底路径：完全重建流（`updateConfiguration/updateContentFilter` 不生效时用）。
    /// 反复调用安全：300ms 内的重复请求会被合并（filter/config 已是最新值，不会丢状态）。
    func restart() {
        onMain { [weak self] in
            guard let self else { return }
            guard let filter = self.filter, let configuration = self.configuration else {
                Log.warn("restart 被忽略：还没有可用的 filter/configuration")
                return
            }
            let now = ProcessInfo.processInfo.systemUptime
            if now - self.lastRestartUptime < Self.restartCoalesce {
                Log.debug("restart 合并：距上次重建不足 \(Self.restartCoalesce)s")
                return
            }
            self.delegate?.captureWillRestart()
            self.lastRestartUptime = now
            self.pendingConfiguration = nil
            do {
                try self.start(filter: filter, configuration: configuration)
                Log.debug("捕获流已重建")
            } catch {
                Log.error("重建捕获流失败：\(error.localizedDescription)")
                self.delegate?.captureDidStop(error: error)
            }
        }
    }

    private func applyConfiguration(_ configuration: SCStreamConfiguration) {
        guard let stream else { return }
        stream.updateConfiguration(configuration) { [weak self] error in
            DispatchQueue.main.async { [weak self] in
                guard let self, self.stream === stream else { return }
                guard let error else { return }
                Log.warn("updateConfiguration 失败：\(error.localizedDescription)，改为重建流")
                self.restart()
            }
        }
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        // 本方法运行在 frameQueue 上：只做闸门判断与转发，不碰 UI、不持有 buffer
        guard type == .screen else { return }
        guard CMSampleBufferIsValid(sampleBuffer),
              CMSampleBufferGetImageBuffer(sampleBuffer) != nil else { return }
        guard FrameGate.accept(sampleBuffer) else { return }
        noteFrameArrived()
        delegate?.captureDidOutput(sampleBuffer)
    }

    // MARK: - SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.stream === stream else { return }   // 旧流的迟到回调忽略
            Log.warn("捕获流意外停止：\(error.localizedDescription)")
            self.tearDownStream()
            self.delegate?.captureDidStop(error: error)
        }
    }

    // MARK: - 卡流检测

    /// 内部定时器：超过 `max(2s, 3/fps)` 没收到有效帧就报一次 `captureDidStall()`（主线程）。
    /// 源窗口最小化、所在 Space 不可见时 SCK 会停止产出 `.complete` 帧，靠这个感知。
    private func startStallWatchdog() {
        stallLock.lock()
        lastFrameUptime = ProcessInfo.processInfo.systemUptime
        stallReported = false
        stallLock.unlock()

        guard stallTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 1.0, repeating: 1.0, leeway: .milliseconds(200))
        timer.setEventHandler { [weak self] in self?.checkStall() }
        stallTimer = timer
        timer.resume()
    }

    private func stopStallWatchdog() {
        stallTimer?.cancel()
        stallTimer = nil
    }

    private func checkStall() {
        guard isRunning else { return }
        let threshold = max(2.0, 3.0 / Double(max(1, currentFPS)))
        stallLock.lock()
        let elapsed = ProcessInfo.processInfo.systemUptime - lastFrameUptime
        let alreadyReported = stallReported
        let shouldReport = elapsed >= threshold && !alreadyReported
        if shouldReport { stallReported = true }
        stallLock.unlock()

        guard shouldReport else { return }
        Log.debug("捕获卡流：\(String(format: "%.1f", elapsed))s 未收到有效帧")
        delegate?.captureDidStall()
    }

    /// 在 frameQueue 上调用：记录帧到达时间并解除 stall 标记（下次卡住会重新上报一次）。
    private func noteFrameArrived() {
        stallLock.lock()
        lastFrameUptime = ProcessInfo.processInfo.systemUptime
        stallReported = false
        stallLock.unlock()
    }

    // MARK: - 私有工具

    /// 拆掉当前流（不动 filter/config，不回调 delegate）。主线程调用。
    private func tearDownStream() {
        stopStallWatchdog()
        isRunning = false
        guard let stream else { return }
        self.stream = nil
        // 先摘输出再停流，避免拆流过程中还有帧回调进来
        try? stream.removeStreamOutput(self, type: .screen)
        stream.stopCapture { error in
            if let error { Log.debug("停止捕获返回：\(error.localizedDescription)") }
        }
    }

    private func onMain(_ block: @escaping () -> Void) {
        if Thread.isMainThread { block() } else { DispatchQueue.main.async(execute: block) }
    }
}
