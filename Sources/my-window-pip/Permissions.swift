import AppKit
import CoreGraphics

/// 权限检查与引导。屏幕录制是硬依赖；辅助功能仅"增强模式"需要。
enum Permissions {

    // MARK: - 屏幕录制

    /// 不弹窗的预检。
    static var hasScreenRecording: Bool { CGPreflightScreenCaptureAccess() }

    /// 首次调用会触发系统授权弹窗；已被拒绝时直接返回 false。
    @discardableResult
    static func requestScreenRecording() -> Bool { CGRequestScreenCaptureAccess() }

    /// 确保拥有屏幕录制权限，没有则引导用户。返回是否可继续。
    @discardableResult
    static func ensureScreenRecording() -> Bool {
        if hasScreenRecording { return true }
        if requestScreenRecording() { return true }
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

            请在「系统设置 → 隐私与安全性 → 屏幕录制与系统录音」中勾选 MyWindowPip，然后重新启动本应用。

            画面只在本机内存中流转，不会被保存或上传。
            """,
            """
            MyWindowPip mirrors windows via the system ScreenCaptureKit framework, which requires the \
            "Screen & System Audio Recording" permission.

            Enable MyWindowPip in System Settings → Privacy & Security → Screen & System Audio Recording, \
            then relaunch the app.

            Frames stay in local memory and are never saved or uploaded.
            """
        )
        alert.addButton(withTitle: L.t("打开系统设置", "Open System Settings"))
        alert.addButton(withTitle: L.t("稍后", "Later"))
        activateForDialog()
        if alert.runModal() == .alertFirstButtonReturn {
            openScreenRecordingSettings()
        }
    }

    static func openScreenRecordingSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
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
