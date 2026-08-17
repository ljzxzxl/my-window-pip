import AppKit
import CoreMedia
import ScreenCaptureKit

/// 命令行自检：`my-window-pip --selftest`
///
/// 不打开任何界面，直接跑一遍「权限 → 窗口枚举 → 建流 → 收帧」的完整链路并打印结果，
/// 用于构建后快速验证运行时是否正常（CI 与本地都能跑）。
enum SelfTest {

    static func shouldRun() -> Bool {
        CommandLine.arguments.contains("--selftest") || CommandLine.arguments.contains("--diagnose")
    }

    /// 返回进程退出码。
    static func run() -> Int32 {
        print("MyWindowPip 自检 v\(Updater.currentVersion)")
        print("系统：\(ProcessInfo.processInfo.operatingSystemVersionString)")
        print("架构：\(machineArch())")
        print("屏幕：", NSScreen.screens.map {
            "\(Int($0.frame.width))×\(Int($0.frame.height))@\($0.backingScaleFactor)x"
        }.joined(separator: ", "))
        print("屏幕录制权限：\(Permissions.hasScreenRecording ? "已授权" : "未授权")")
        print("辅助功能权限：\(Permissions.hasAccessibility ? "已授权" : "未授权（精确回源与增强模式不可用）")")

        guard Permissions.hasScreenRecording else {
            print("→ 缺少屏幕录制权限，无法验证捕获链路。")
            print("  请在「系统设置 → 隐私与安全性 → 屏幕录制与系统录音」中勾选本 App 后重试。")
            return 2
        }

        // 枚举窗口（完成回调派发到主线程，因此这里必须跑 runloop 而不能阻塞主线程等信号量）
        var windows: [SCWindow] = []
        var enumerateDone = false
        ShareableContentStore.shared.refresh { result in
            if case let .success(list) = result { windows = list }
            enumerateDone = true
        }
        let enumerateDeadline = Date().addingTimeInterval(8)
        while !enumerateDone, Date() < enumerateDeadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        guard enumerateDone else {
            print("→ 窗口枚举超时")
            return 3
        }
        print("可捕获窗口：\(windows.count) 个")
        // 全量枚举包含其他 Space 与最小化窗口；自检必须只挑当前能稳定产出帧的 onscreen 窗口。
        let onScreen = windows.filter { $0.isOnScreen }
        // 优先挑普通层（windowLayer == 0）的最大窗口，避免选到 Dock 这类系统层窗口
        let normalLayer = onScreen.filter { $0.windowLayer == 0 }
        let pool = normalLayer.isEmpty ? onScreen : normalLayer
        guard let target = pool.max(by: {
            $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height
        }) else {
            print("→ 没有可捕获的窗口，跳过捕获验证")
            return 0
        }
        let title = ShareableContentStore.shared.displayTitle(for: target)
        print("测试目标：\(title) [\(Int(target.frame.width))×\(Int(target.frame.height))]")

        // 建流并收帧
        let engine = CaptureEngine()
        let probe = FrameProbe()
        engine.delegate = probe
        let config = CaptureEngine.makeConfiguration(
            sourceRect: CGRect(origin: .zero, size: target.frame.size),
            pointSize: target.frame.size,
            scale: 1,
            fps: 15,
            showsCursor: false
        )
        do {
            try engine.start(filter: CaptureEngine.filter(for: target), configuration: config)
        } catch {
            print("→ 建流失败：\(error.localizedDescription)")
            return 4
        }
        // 用 runloop 等待，保证主线程回调能被派发
        let deadline = Date().addingTimeInterval(2.0)
        while Date() < deadline, probe.frameCount < 10 {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        engine.stop()

        print("收到有效帧：\(probe.frameCount) 帧（2 秒 / 15fps）")
        if let size = probe.lastPixelSize {
            print("帧尺寸：\(Int(size.width))×\(Int(size.height))")
        }
        if probe.frameCount == 0 {
            print("→ 未收到任何帧，捕获链路异常")
            return 5
        }
        print("自检通过")
        return 0
    }

    private static func machineArch() -> String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unknown"
        #endif
    }
}

/// 自检用的帧接收器。
private final class FrameProbe: CaptureEngineDelegate {
    private let lock = NSLock()
    private var frames = 0
    private var size: CGSize?

    var frameCount: Int { lock.lock(); defer { lock.unlock() }; return frames }
    var lastPixelSize: CGSize? { lock.lock(); defer { lock.unlock() }; return size }

    func captureDidOutput(_ sampleBuffer: CMSampleBuffer) {
        lock.lock()
        frames += 1
        if let px = sampleBuffer.imageBuffer {
            size = CGSize(width: CVPixelBufferGetWidth(px), height: CVPixelBufferGetHeight(px))
        }
        lock.unlock()
    }

    func captureDidStop(error: Error?) {
        if let error { print("流停止：\(error.localizedDescription)") }
    }

    func captureDidStall() { print("提示：一段时间没有新帧（窗口内容可能完全静止）") }
}
