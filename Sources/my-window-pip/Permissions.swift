import AppKit
import CoreGraphics
import ScreenCaptureKit

/// 权限检查与引导。屏幕录制是硬依赖；辅助功能仅"增强模式"需要。
enum Permissions {

    // MARK: - 屏幕录制

    /// 不弹窗的预检。
    static var hasScreenRecording: Bool { CGPreflightScreenCaptureAccess() }

    /// 首次调用会触发系统授权弹窗；已被拒绝时直接返回 false。
    @discardableResult
    static func requestScreenRecording() -> Bool { CGRequestScreenCaptureAccess() }

    /// 让系统把本应用登记进「屏幕录制与系统录音」列表。
    ///
    /// TCC 只在应用**真正发起过**屏幕捕获请求后才会创建条目——没请求过，
    /// 系统设置里就没有本应用，用户只能手动点加号添加（v0.1.0 的 bug 就是这个）。
    /// 这里做两件事：
    /// 1. `CGRequestScreenCaptureAccess()` 触发系统授权弹窗并写入 TCC 条目
    /// 2. 再发一次 ScreenCaptureKit 查询，确保 SCK 侧也完成登记（失败被系统吞掉是正常的）
    @discardableResult
    static func primeRegistration() -> Bool {
        let granted = CGRequestScreenCaptureAccess()
        Task.detached(priority: .utility) {
            _ = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        }
        return granted
    }

    /// 确保拥有屏幕录制权限：先向系统申请（顺带完成列表登记），仍未授权才显示引导。
    @discardableResult
    static func ensureScreenRecording() -> Bool {
        if hasScreenRecording { return true }
        if primeRegistration() { return true }
        // 系统弹窗是异步的，用户可能刚点了「允许」，复检一次避免多弹一个框
        if hasScreenRecording { return true }
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

            画面只在本机内存中流转，不会被保存或上传。
            """,
            """
            MyWindowPip mirrors windows via the system ScreenCaptureKit framework, which requires the \
            "Screen & System Audio Recording" permission.

            1. Open System Settings → Privacy & Security → Screen & System Audio Recording
            2. Find MyWindowPip in the list and turn the switch on
            3. Relaunch MyWindowPip (macOS only applies the grant after a restart)

            Frames stay in local memory and are never saved or uploaded.
            """
        )
        alert.addButton(withTitle: L.t("打开系统设置", "Open System Settings"))
        alert.addButton(withTitle: L.t("重新启动应用", "Relaunch app"))
        alert.addButton(withTitle: L.t("稍后", "Later"))
        activateForDialog()
        switch alert.runModal() {
        case .alertFirstButtonReturn: openScreenRecordingSettings()
        case .alertSecondButtonReturn: relaunch()
        default: break
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

    // MARK: - 辅助功能（增强模式）

    static var hasAccessibility: Bool { AXIsProcessTrusted() }

    static func showAccessibilityGuide() {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = L.t("增强模式需要「辅助功能」权限", "Enhanced mode requires Accessibility")
        alert.informativeText = L.t(
            """
            增强模式用于支持 fn 组合热键，以及鼠标悬停在浮窗上时的快捷键（= - F D fn ⌫）。

            请在「系统设置 → 隐私与安全性 → 辅助功能」中勾选 MyWindowPip。

            不开启增强模式也能正常使用：默认热键为 ⌃⌥P，浮窗操作可用悬浮按钮与右键菜单。
            """,
            """
            Enhanced mode enables fn-based hotkeys and hover keyboard shortcuts (= - F D fn ⌫).

            Enable MyWindowPip in System Settings → Privacy & Security → Accessibility.

            The app works fine without it: the default hotkey is ⌃⌥P and every action is available \
            from the overlay buttons and right-click menu.
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
