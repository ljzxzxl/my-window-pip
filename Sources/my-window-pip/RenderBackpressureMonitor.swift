import Foundation

/// 渲染背压状态机。
///
/// `AVSampleBufferVideoRenderer.isReadyForMoreMediaData == false` 本身并不是错误：短暂的
/// false 只是内部队列正在消化已有帧。真正需要处理的是「捕获帧持续到达，但 renderer
/// 长时间不再 ready」。状态机把恢复动作逐级升级，避免一次瞬时背压就 flush，也避免
/// renderer 永久停在旧画面：
///
///     等待 timeout → flush → 再等 timeout → 重建 layer → 再等 timeout → 重启捕获流
///
/// 本类型不依赖 AVFoundation，便于用确定性的单元测试覆盖所有时间边界。
struct RenderBackpressureMonitor {

    enum RecoveryAction: Equatable {
        case none
        case flush
        case rebuildLayer
        case restartCapture
    }

    private enum Phase: Equatable {
        case healthy
        case waiting(since: TimeInterval)
        case flushed(since: TimeInterval)
        case rebuilt(since: TimeInterval)
        case exhausted
    }

    let timeout: TimeInterval

    private var phase: Phase = .healthy
    private var stallStartedAt: TimeInterval?

    init(timeout: TimeInterval) {
        self.timeout = max(0.25, timeout)
    }

    var isRecovering: Bool { phase != .healthy }

    /// renderer 恢复接收。返回本轮背压持续时间；原本健康时返回 nil。
    mutating func observeReady(at now: TimeInterval) -> TimeInterval? {
        guard let started = stallStartedAt else {
            phase = .healthy
            return nil
        }
        let duration = max(0, now - started)
        reset()
        return duration
    }

    /// renderer 当前不接收新帧；只在跨过恢复时间边界时返回动作。
    mutating func observeNotReady(at now: TimeInterval) -> RecoveryAction {
        switch phase {
        case .healthy:
            stallStartedAt = now
            phase = .waiting(since: now)
            return .none

        case let .waiting(since):
            guard elapsed(since, now) >= timeout else { return .none }
            phase = .flushed(since: now)
            return .flush

        case let .flushed(since):
            guard elapsed(since, now) >= timeout else { return .none }
            phase = .rebuilt(since: now)
            return .rebuildLayer

        case let .rebuilt(since):
            guard elapsed(since, now) >= timeout else { return .none }
            phase = .exhausted
            return .restartCapture

        case .exhausted:
            return .none
        }
    }

    /// 已知 renderer/时间线发生不连续时跳过等待，立即从 flush 这一级开始恢复。
    mutating func requestImmediateFlush(at now: TimeInterval) -> RecoveryAction {
        switch phase {
        case .healthy, .waiting:
            if stallStartedAt == nil { stallStartedAt = now }
            phase = .flushed(since: now)
            return .flush
        case .flushed, .rebuilt, .exhausted:
            return .none
        }
    }

    mutating func reset() {
        phase = .healthy
        stallStartedAt = nil
    }

    private func elapsed(_ since: TimeInterval, _ now: TimeInterval) -> TimeInterval {
        max(0, now - since)
    }
}
