import AppKit

// 菜单栏常驻应用（LSUIElement），无 Dock 图标、无主窗口。
let app = NSApplication.shared
let appDelegate = AppDelegate()
app.delegate = appDelegate
app.setActivationPolicy(.accessory)
app.run()
