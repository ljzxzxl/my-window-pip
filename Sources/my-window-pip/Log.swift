import Foundation

/// 轻量分级日志。用 `--debug` 构建（-D DEBUG）时才输出 debug 级别。
///
/// 只有 warn / error 会写入本地滚动日志——事故现场快照本身就是 `Log.warn`，排障能力不减，
/// 而 info 级里带着窗口标题（「新建窗口 PiP：<标题>」），正常使用不应该把它留在磁盘上。
/// 日志永不上传。
enum Log {
    private static let prefix = "[MyWindowPip]"
    private static let maxLogBytes: UInt64 = 2 * 1024 * 1024
    /// 落盘串行队列：帧回调也会打日志，磁盘 I/O 绝不能占着锁卡住捕获队列或主线程。
    private static let fileQueue = DispatchQueue(
        label: "com.ljzxzxl.mywindowpip.log", qos: .utility
    )
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

    private static func emit(_ level: String, _ items: [Any], persist: Bool) {
        let msg = items.map { "\($0)" }.joined(separator: " ")
        let line = "\(prefix)[\(formatter.string(from: Date()))][\(level)] \(msg)"
        print(line)
        guard persist else { return }
        fileQueue.async { appendToFile(line + "\n") }
    }

    /// 只在 `fileQueue` 上调用；队列本身串行，不需要额外加锁。
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
        emit("D", items, persist: false)
        #endif
    }

    static func info(_ items: Any...) { emit("I", items, persist: false) }
    static func warn(_ items: Any...) { emit("W", items, persist: true) }
    static func error(_ items: Any...) { emit("E", items, persist: true) }
}
