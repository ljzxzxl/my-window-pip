import CoreMedia
import Foundation

/// 内容级静止检测：靠抽样帧指纹判断「有帧但画面几乎不变」（例如只有光标在闪的终端），
/// 达到阈值后建议降到 1 fps；一旦指纹变化立刻建议恢复用户设定的帧率。
///
/// 约定：每个会话一个实例，**只在捕获队列上调用**（`feed` / `reset` / `isIdle` 都不加锁）。
final class IdleDetector {

    /// 静止时建议的帧率
    static let idleFPS = 1

    /// 连续无变化多久判定为静止
    private let idleSeconds: TimeInterval
    /// 活跃状态下每 N 帧算一次指纹（静止状态下每帧都算，见 `feed`）
    private let sampleEveryNFrames: Int

    private var lastFingerprint: UInt64?
    /// 最近一次「画面确实变了」的时间（`systemUptime`，单调）
    private var lastChangeUptime: TimeInterval
    private var frameIndex = 0

    /// 当前是否判定为静止
    private(set) var isIdle = false

    init(idleSeconds: TimeInterval = 3.0, sampleEveryNFrames: Int = 4) {
        self.idleSeconds = max(0.5, idleSeconds)
        self.sampleEveryNFrames = max(1, sampleEveryNFrames)
        self.lastChangeUptime = ProcessInfo.processInfo.systemUptime
    }

    /// 喂入一帧（必须是已过 `FrameGate.accept` 的 `.complete` 帧）。
    /// - Parameter activeFPS: 用户当前设定的帧率，用于从静止恢复时告诉上层该回到多少
    /// - Returns: 需要改变帧率时返回结论；无需变更返回 nil
    func feed(_ sb: CMSampleBuffer, activeFPS: Int) -> IdleVerdict? {
        frameIndex &+= 1
        let now = ProcessInfo.processInfo.systemUptime

        // 抽样策略：活跃时每 N 帧算一次指纹（省 CPU）；已判定静止时每帧都算 ——
        // 静止后帧率只有 1 fps，帧本身很稀疏，必须每帧都看才能做到 1 秒内唤醒。
        if !isIdle, sampleEveryNFrames > 1, frameIndex % sampleEveryNFrames != 0 {
            // 不抽样的帧用脏矩形兜底：SCK 报告有脏区就说明画面确实动了，刷新计时即可
            if let dirty = FrameGate.dirtyRectCount(sb), dirty > 0 { lastChangeUptime = now }
            return nil
        }

        guard let fingerprint = FrameGate.fingerprint(sb) else {
            // 指纹不可用（非 BGRA / 锁定失败）：保守当作有变化，宁可不降帧也不误降
            lastChangeUptime = now
            lastFingerprint = nil
            return isIdle ? wake(activeFPS: activeFPS) : nil
        }

        if let last = lastFingerprint, last == fingerprint {
            guard !isIdle, now - lastChangeUptime >= idleSeconds else { return nil }
            isIdle = true
            // 用户已经在 1 fps 及以下，没有可降的空间，只记录状态不打扰上层
            guard activeFPS > Self.idleFPS else {
                Log.debug("静止检测：已静止，但当前帧率已是 \(activeFPS) fps，无需调整")
                return nil
            }
            Log.debug("静止检测：判定静止（\(String(format: "%.1f", now - lastChangeUptime))s 无变化）→ \(Self.idleFPS) fps")
            return IdleVerdict(isIdle: true, suggestedFPS: Self.idleFPS)
        }

        lastFingerprint = fingerprint
        lastChangeUptime = now
        return isIdle ? wake(activeFPS: activeFPS) : nil
    }

    /// 清空状态（切换源、恢复流、用户手动改帧率后调用）。
    func reset() {
        lastFingerprint = nil
        lastChangeUptime = ProcessInfo.processInfo.systemUptime
        frameIndex = 0
        if isIdle { Log.debug("静止检测：状态重置") }
        isIdle = false
    }

    private func wake(activeFPS: Int) -> IdleVerdict {
        isIdle = false
        let fps = min(max(activeFPS, 1), 60)
        Log.debug("静止检测：画面恢复变化 → \(fps) fps")
        return IdleVerdict(isIdle: false, suggestedFPS: fps)
    }
}
