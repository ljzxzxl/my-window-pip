import Foundation

/// 轻量分级日志。用 `--debug` 构建（-D DEBUG）时才输出 debug 级别。
enum Log {
    private static let prefix = "[MyWindowPip]"
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    private static func emit(_ level: String, _ items: [Any]) {
        let msg = items.map { "\($0)" }.joined(separator: " ")
        print("\(prefix)[\(formatter.string(from: Date()))][\(level)] \(msg)")
    }

    static func debug(_ items: Any...) {
        #if DEBUG
        emit("D", items)
        #endif
    }

    static func info(_ items: Any...) { emit("I", items) }
    static func warn(_ items: Any...) { emit("W", items) }
    static func error(_ items: Any...) { emit("E", items) }
}
