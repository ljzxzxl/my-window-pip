import Foundation

/// 轻量分级日志。用 `--debug` 构建（-D DEBUG）时才输出 debug 级别。
/// info / warn / error（以及 DEBUG 构建中的 debug）同时写入本地滚动日志，永不上传。
enum Log {
    private static let prefix = "[MyWindowPip]"
    private static let lock = NSLock()
    private static let maxLogBytes: UInt64 = 2 * 1024 * 1024
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS Z"
        return f
    }()

    static let fileURL: URL = {
        let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library")
        return library
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("MyWindowPip", isDirectory: true)
            .appendingPathComponent("MyWindowPip.log")
    }()

    static var filePath: String { fileURL.path }

    private static func emit(_ level: String, _ items: [Any]) {
        let msg = items.map { "\($0)" }.joined(separator: " ")
        lock.lock()
        defer { lock.unlock() }

        let line = "\(prefix)[\(formatter.string(from: Date()))][\(level)] \(msg)"
        print(line)
        appendToFile(line + "\n")
    }

    /// 必须在 `lock` 内调用。
    private static func appendToFile(_ text: String) {
        let manager = FileManager.default
        let directory = fileURL.deletingLastPathComponent()
        do {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
            try rotateIfNeeded(using: manager)
            if !manager.fileExists(atPath: fileURL.path) {
                try Data().write(to: fileURL, options: .atomic)
            }
            let handle = try FileHandle(forWritingTo: fileURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(text.utf8))
        } catch {
            // 日志绝不能影响捕获或 UI；控制台输出仍然保留。
        }
    }

    private static func rotateIfNeeded(using manager: FileManager) throws {
        guard let attributes = try? manager.attributesOfItem(atPath: fileURL.path),
              let size = attributes[.size] as? NSNumber,
              size.uint64Value >= maxLogBytes else { return }

        let previous = fileURL.deletingPathExtension().appendingPathExtension("previous.log")
        if manager.fileExists(atPath: previous.path) { try manager.removeItem(at: previous) }
        try manager.moveItem(at: fileURL, to: previous)
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
