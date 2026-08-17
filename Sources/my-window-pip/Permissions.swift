import AppKit
import CoreGraphics
import ScreenCaptureKit

/// 权限检查与引导。屏幕录制是硬依赖；辅助功能仅"增强模式"需要。
enum Permissions {

    // MARK: - 屏幕录制

    /// 原子记录本进程是否已经触发过系统授权请求，避免并发入口重复请求或叠加 App 引导。
    private final class ScreenRecordingRequestState: @unchecked Sendable {
        private let lock = NSLock()
        private var didRequest = false

        /// 首个调用方把状态置为已请求并返回 true；后续调用返回 false。
        func beginRequestIfNeeded() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard !didRequest else { return false }
            didRequest = true
            return true
        }
    }

    private static let screenRecordingRequestState = ScreenRecordingRequestState()

    /// 不弹窗的预检。
    static var hasScreenRecording: Bool { CGPreflightScreenCaptureAccess() }

    /// 让系统把本应用登记进「屏幕录制与系统录音」列表。
    ///
    /// TCC 只在应用**真正发起过**屏幕捕获请求后才会创建条目——没请求过，
    /// 系统设置里就没有本应用，用户只能手动点加号添加（v0.1.0 的 bug 就是这个）。
    /// 这里做两件事：
    /// 1. `CGRequestScreenCaptureAccess()` 触发系统授权弹窗并写入 TCC 条目
    /// 2. 再发一次 ScreenCaptureKit 查询，确保 SCK 侧也完成登记（失败被系统吞掉是正常的）
    @discardableResult
    private static func primeRegistration() -> Bool {
        let granted = CGRequestScreenCaptureAccess()
        Task.detached(priority: .utility) {
            _ = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        }
        return granted
    }

    /// 确保拥有屏幕录制权限。
    ///
    /// 首次调用只发起 macOS 系统授权：系统弹窗是实际授予 TCC 权限的唯一入口，不与 App
    /// 自己的说明框叠加。若本次启动已经请求过、用户之后仍主动触发捕获或点击权限菜单，
    /// 才显示 App 引导，提供系统设置、重置记录与重启入口。
    @discardableResult
    static func ensureScreenRecording() -> Bool {
        if hasScreenRecording { return true }
        if screenRecordingRequestState.beginRequestIfNeeded() {
            _ = primeRegistration()
            // 系统授权可能要求重启应用才生效；这里只复检，不在同一轮再弹 App 引导。
            return hasScreenRecording
        }
        showScreenRecordingGuide()
        return false
    }

    static func showScreenRecordingGuide() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L.t("需要「屏幕录制」权限", "Screen Recording permission required")
        alert.informativeText = L.t(
            """
            MyWindowPip 通过系统的 ScreenCaptureKit 把窗口画面镜像到浮窗，因此需要「屏幕录制与系统录音」权限。

            1. 打开「系统设置 → 隐私与安全性 → 屏幕录制与系统录音」
            2. 在列表中找到 MyWindowPip，打开右侧开关
            3. 重新启动 MyWindowPip（macOS 要求重启应用后权限才生效）

            如果列表里已经有 MyWindowPip、开关也是开的，说明是旧版本留下的失效记录：点「重置授权记录」再重启，即可重新授权，不必手动减号删除。

            画面只在本机内存中流转，不会被保存或上传。
            """,
            """
            MyWindowPip mirrors windows via the system ScreenCaptureKit framework, which requires the \
            "Screen & System Audio Recording" permission.

            1. Open System Settings → Privacy & Security → Screen & System Audio Recording
            2. Find MyWindowPip in the list and turn the switch on
            3. Relaunch MyWindowPip (macOS only applies the grant after a restart)

            If MyWindowPip is already listed and switched on, the entry is a stale record left by an \
            older build: click "Reset permission record", then relaunch — no need to remove it manually.

            Frames stay in local memory and are never saved or uploaded.
            """
        )
        alert.addButton(withTitle: L.t("打开系统设置", "Open System Settings"))
        alert.addButton(withTitle: L.t("重置授权记录", "Reset permission record"))
        alert.addButton(withTitle: L.t("重新启动应用", "Relaunch app"))
        alert.addButton(withTitle: L.t("稍后", "Later"))
        activateForDialog()
        switch alert.runModal() {
        case .alertFirstButtonReturn: openScreenRecordingSettings()
        case .alertSecondButtonReturn: resetScreenRecordingRecordWithGuide()
        case .alertThirdButtonReturn: relaunch()
        default: break
        }
    }

    /// 清除本应用的录屏授权记录，并根据结果引导下一步。
    static func resetScreenRecordingRecordWithGuide() {
        let succeeded = resetScreenRecordingRecord()
        let alert = NSAlert()
        alert.alertStyle = succeeded ? .informational : .warning
        if succeeded {
            alert.messageText = L.t("已清除授权记录", "Permission record cleared")
            alert.informativeText = L.t(
                """
                重新启动 MyWindowPip 后，系统会再次询问屏幕录制权限，点「允许」即可。

                这次授权之后的版本更新都不会再要求重新授权。
                """,
                """
                After relaunching MyWindowPip, macOS will ask for Screen Recording again — click Allow.

                Once granted, future updates will keep the permission.
                """
            )
            alert.addButton(withTitle: L.t("重新启动应用", "Relaunch app"))
            alert.addButton(withTitle: L.t("稍后", "Later"))
            activateForDialog()
            if alert.runModal() == .alertFirstButtonReturn { relaunch() }
        } else {
            alert.messageText = L.t("未能清除授权记录", "Could not clear the permission record")
            alert.informativeText = L.t(
                """
                请手动处理：打开「系统设置 → 隐私与安全性 → 屏幕录制与系统录音」，
                选中 MyWindowPip 后点减号删除，再点加号重新添加，然后重启应用。
                """,
                """
                Please do it manually: open System Settings → Privacy & Security → \
                Screen & System Audio Recording, select MyWindowPip and remove it with −, \
                add it again with +, then relaunch the app.
                """
            )
            alert.addButton(withTitle: L.t("打开系统设置", "Open System Settings"))
            alert.addButton(withTitle: L.t("好", "OK"))
            activateForDialog()
            if alert.runModal() == .alertFirstButtonReturn { openScreenRecordingSettings() }
        }
    }

    /// 重置本应用的录屏授权记录。
    ///
    /// ad-hoc 签名的旧版本在 TCC 里留下的是按 cdhash 钉死的记录：升级到固定身份签名的新版本后，
    /// 那条记录既匹配不上、又占着列表位置，用户只能手动减号删除再加号添加。
    /// `tccutil reset` 操作的是当前用户的隐私数据库，不需要管理员权限；
    /// 只重置 ScreenCapture，避免顺手清掉用户的辅助功能等其它授权。
    @discardableResult
    static func resetScreenRecordingRecord() -> Bool {
        guard let bundleID = Bundle.main.bundleIdentifier else { return false }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        process.arguments = ["reset", "ScreenCapture", bundleID]
        do {
            try process.run()
            process.waitUntilExit()
            let ok = process.terminationStatus == 0
            if !ok { Log.error("tccutil 退出码 \(process.terminationStatus)") }
            return ok
        } catch {
            Log.error("重置录屏授权记录失败：\(error.localizedDescription)")
            return false
        }
    }

    static func openScreenRecordingSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
    }

    /// 原地重启本应用（授权后必须重启才生效）。失败时提示手动重开。
    static func relaunch() {
        let url = Bundle.main.bundleURL
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, error in
            DispatchQueue.main.async {
                if let error {
                    Log.error("重启失败：\(error.localizedDescription)")
                    let alert = NSAlert()
                    alert.messageText = L.t("无法自动重启", "Could not relaunch automatically")
                    alert.informativeText = L.t("请手动退出并重新打开 MyWindowPip。",
                                                "Please quit and open MyWindowPip again manually.")
                    alert.addButton(withTitle: L.t("好", "OK"))
                    alert.runModal()
                    return
                }
                NSApp.terminate(nil)
            }
        }
    }

    // MARK: - 辅助功能（精确回源 / 增强模式）

    static var hasAccessibility: Bool { AXIsProcessTrusted() }

    static func showAccessibilityGuide() {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = L.t("这些功能需要「辅助功能」权限", "These features require Accessibility")
        alert.informativeText = L.t(
            """
            「辅助功能」权限用于：
            · 单击浮窗时切换到对应的具体源窗口
            · 增强模式的 fn 组合热键与悬停快捷键（= - F D fn ⌫）

            请在「系统设置 → 隐私与安全性 → 辅助功能」中勾选 MyWindowPip。

            未授权时仍可正常捕获；单击浮窗只能激活源应用，由应用决定显示哪个窗口。
            """,
            """
            Accessibility is used to:
            · Switch to the exact source window when a PiP is clicked
            · Enable fn-based hotkeys and hover shortcuts (= - F D fn ⌫) in Enhanced mode

            Enable MyWindowPip in System Settings → Privacy & Security → Accessibility.

            Capture still works without it; clicking a PiP can only activate the source application, \
            which then chooses which window to show.
            """
        )
        alert.addButton(withTitle: L.t("打开系统设置", "Open System Settings"))
        alert.addButton(withTitle: L.t("取消", "Cancel"))
        activateForDialog()
        if alert.runModal() == .alertFirstButtonReturn {
            openAccessibilitySettings()
        }
    }

    static func openAccessibilitySettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    // MARK: - 工具

    private static func open(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }

    /// LSUIElement 应用弹 modal 前需要先激活，否则弹窗可能藏在后面。
    private static func activateForDialog() {
        NSApp.activate(ignoringOtherApps: true)
    }
}
