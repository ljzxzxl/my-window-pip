import Foundation

/// 整屏 / 区域会话的卡流恢复节奏。纯值类型，不触碰 AppKit 或 SCK，便于确定性回归测试。
///
/// `CaptureEngine` 在「一段时间没有有效帧」时只上报一次 transport stall。画面长时间静止、
/// 源窗口进入原生全屏 Space 等情况都可能让 SCK 暂时停帧，这并不代表捕获目标消失了。
/// 旧逻辑用 2 秒 repeating timer 无条件 `restart()`，而每次重启都会把 stall watchdog 的
/// `lastFrameUptime` 重置成当前时刻，于是 2 秒后又上报一次 stall —— 静止画面被当成断流，
/// 进入「每 2 秒重建一次捕获流」的风暴：画面始终冻在最后一帧，CPU 与日志却持续被打扰。
///
/// 现在的节奏：
/// - 连续 stall 期间最多主动重建 3 次，间隔按 2s / 4s / 8s 退避；
/// - 达到上限后转入 30s 一次的健康检查：显示器拔掉时静默等待；重新接回时立刻重建；
///   一直接着也只是每 10 次检查（约 5 分钟）稀疏重建一次，避免永久冻帧；
/// - 任何真实帧到达、用户暂停/恢复或屏幕参数变化都会 `reset()` 回到起点。
struct DisplayStallRecovery {

    static let restartDelays: [TimeInterval] = [2, 4, 8]
    static let healthCheckDelay: TimeInterval = 30
    static let healthChecksPerSparseRestart = 10

    enum Action: Equatable {
        case restart(delay: TimeInterval)
        case healthCheck(delay: TimeInterval)

        var delay: TimeInterval {
            switch self {
            case let .restart(delay), let .healthCheck(delay): return delay
            }
        }
    }

    /// 本轮连续 stall 已经计划的主动重建次数
    private(set) var restartCount = 0
    /// 达到上限后累计的健康检查次数
    private(set) var healthChecks = 0
    /// 上一次健康检查时显示器是否已经不在
    private(set) var displayIsMissing = false

    /// 安排下一次恢复动作。重复调用只推进计划，不负责执行。
    mutating func schedule() -> Action {
        guard restartCount < Self.restartDelays.count else {
            return .healthCheck(delay: Self.healthCheckDelay)
        }
        let delay = Self.restartDelays[restartCount]
        restartCount += 1
        return .restart(delay: delay)
    }

    /// 健康检查的结果：是否需要立刻重建捕获流。
    ///
    /// - 显示器重新接回：重置整轮退避并重建；
    /// - 显示器仍缺失：只记录，静默等待，绝不重启；
    /// - 显示器一直在但长时间无帧：每 10 次检查稀疏重建一次。
    mutating func observeHealth(displayPresent: Bool) -> Bool {
        let reappeared = displayIsMissing && displayPresent
        displayIsMissing = !displayPresent
        if reappeared {
            reset()
            return true
        }
        guard displayPresent else { return false }
        healthChecks += 1
        guard healthChecks >= Self.healthChecksPerSparseRestart else { return false }
        healthChecks = 0
        return true
    }

    /// 真实帧恢复 / 用户显式恢复 / 屏幕参数变化后回到初始节奏。
    mutating func reset() {
        restartCount = 0
        healthChecks = 0
        displayIsMissing = false
    }
}
