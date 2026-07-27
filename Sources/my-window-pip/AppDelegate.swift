import AppKit

/// 应用生命周期与模块装配。
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        installTemporaryStatusItem()
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    // MARK: - 临时状态栏（Task 10 会由 StatusBarController 接管）

    private func installTemporaryStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(
            systemSymbolName: "pip",
            accessibilityDescription: "MyWindowPip"
        )
        let menu = NSMenu()
        menu.addItem(withTitle: "MyWindowPip", action: nil, keyEquivalent: "")
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        menu.addItem(quit)
        item.menu = menu
        statusItem = item
    }
}
