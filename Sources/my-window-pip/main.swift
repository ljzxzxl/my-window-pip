import AppKit

// 命令行自检模式：不开界面，验证权限与捕获链路后退出。
if SelfTest.shouldRun() {
    exit(SelfTest.run())
}

// 菜单栏常驻应用（LSUIElement），无 Dock 图标、无主窗口。
let app = NSApplication.shared
let appDelegate = AppDelegate()
app.delegate = appDelegate
app.setActivationPolicy(.accessory)
app.run()
