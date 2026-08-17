import Foundation

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
        events.append(Event(uptime: uptime, message: message))
        if events.count > capacity {
            events.removeFirst(events.count - capacity)
        }
    }

    func incidentReport(id: String, label: String, at now: TimeInterval,
                        trigger: String, snapshot: String) -> String {
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
        renderer incident \(id)
          source: \(label)
          trigger: \(trigger)
          snapshot: \(snapshot)
          recent events (oldest first):
        \(history)
        """
    }
}
