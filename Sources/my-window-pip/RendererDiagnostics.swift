import Foundation

/// 一次 renderer 事故的两个时间维度，独立于 UI/AVFoundation，便于确定性测试。
struct RendererIncidentTiming: Equatable {
    let stallDuration: TimeInterval
    let recoveryDuration: TimeInterval

    init(stallStartedAt: TimeInterval?, detectedAt: TimeInterval?, recoveredAt: TimeInterval,
         lastPhaseDuration: TimeInterval) {
        stallDuration = stallStartedAt.map { max(0, recoveredAt - $0) }
            ?? max(0, lastPhaseDuration)
        recoveryDuration = detectedAt.map { max(0, recoveredAt - $0) } ?? 0
    }
}

/// 每个 PiP 会话自己的轻量事件环形缓冲。
///
/// 正常运行时事件只留在内存；确认 renderer 卡流后才一次性生成现场快照并落盘，
/// 既能保留问题发生前的因果线索，也避免长期运行时持续刷日志。
struct RendererDiagnostics {

    struct Event: Equatable {
        let uptime: TimeInterval
        let message: String
    }

    let capacity: Int
    private(set) var events: [Event] = []

    init(capacity: Int = 64) {
        self.capacity = max(1, capacity)
    }

    mutating func record(_ message: String, at uptime: TimeInterval) {
        events.append(Event(uptime: uptime, message: Self.singleLine(message)))
        if events.count > capacity {
            events.removeFirst(events.count - capacity)
        }
    }

    func incidentReport(id: String, label: String, at now: TimeInterval,
                        trigger: String, snapshot: String) -> String {
        let safeID = Self.singleLine(id, limit: 64)
        let safeLabel = Self.singleLine(label, limit: 512)
        let safeTrigger = Self.singleLine(trigger)
        let safeSnapshot = Self.singleLine(snapshot)
        let history: String
        if events.isEmpty {
            history = "  (no recent events)"
        } else {
            history = events.map { event in
                let offset = event.uptime - now
                return String(format: "  %+.3fs  %@", offset, event.message)
            }.joined(separator: "\n")
        }

        return """
        renderer incident \(safeID)
          source: \(safeLabel)
          trigger: \(safeTrigger)
          snapshot: \(safeSnapshot)
          recent events (oldest first):
        \(history)
        """
    }

    /// 窗口标题与框架错误属于外部输入；限制为单行和合理长度，避免破坏日志结构。
    private static func singleLine(_ value: String, limit: Int = 2_048) -> String {
        let flattened = value.components(separatedBy: .newlines).joined(separator: " ")
        return String(flattened.prefix(limit))
    }
}
