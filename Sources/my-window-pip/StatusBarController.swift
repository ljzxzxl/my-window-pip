import AppKit
import ScreenCaptureKit

/// 菜单栏图标与菜单。应用没有 Dock 图标，这里是唯一的常驻入口。
final class StatusBarController: NSObject, NSMenuDelegate {

    private let statusItem: NSStatusItem
    private let menu = NSMenu()
    private let windowsMenu = NSMenu()
    private var cachedGroups: [WindowGroup] = []
    private var pendingUpdate: ReleaseInfo?

    private let store = SessionStore.shared
    private let prefs = Preferences.shared

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        statusItem.button?.image = Self.statusImage(hasSessions: false)
        statusItem.button?.image?.isTemplate = true
        statusItem.button?.toolTip = "MyWindowPip"
        menu.delegate = self
        windowsMenu.delegate = self
        statusItem.menu = menu

        store.onChange = { [weak self] in self?.refreshIcon() }
    }

    /// 有新版本时在菜单顶部插入提示项
    func setPendingUpdate(_ info: ReleaseInfo?) {
        pendingUpdate = info
        refreshIcon()
    }

    // MARK: - 图标

    private static func statusImage(hasSessions: Bool) -> NSImage? {
        let name = hasSessions ? "pip.fill" : "pip"
        return NSImage(systemSymbolName: name, accessibilityDescription: "MyWindowPip")
            ?? NSImage(systemSymbolName: "rectangle.on.rectangle", accessibilityDescription: "MyWindowPip")
    }

    private func refreshIcon() {
        statusItem.button?.image = Self.statusImage(hasSessions: store.hasSessions)
        statusItem.button?.image?.isTemplate = true
        let count = store.sessions.count
        statusItem.button?.toolTip = count == 0
            ? "MyWindowPip"
            : L.t("MyWindowPip · \(count) 个浮窗", "MyWindowPip · \(count) PiP window(s)")
    }

    // MARK: - NSMenuDelegate

    func menuWillOpen(_ menu: NSMenu) {
        if menu === self.menu {
            rebuildMenu()
            refreshWindowList()
        } else if menu === windowsMenu {
            refreshWindowList()
        }
    }

    /// 异步刷新窗口列表；NSMenu 允许在打开状态下增删项，因此可以直接原地更新。
    private func refreshWindowList() {
        ShareableContentStore.shared.grouped { [weak self] groups in
            guard let self else { return }
            self.cachedGroups = groups
            self.populateWindowsMenu()
        }
    }

    // MARK: - 菜单构建

    func rebuildMenu() {
        menu.removeAllItems()

        if let update = pendingUpdate {
            let item = NSMenuItem(
                title: L.t("发现新版本 \(update.version)", "Version \(update.version) available"),
                action: #selector(showUpdate), keyEquivalent: ""
            )
            item.target = self
            item.image = NSImage(systemSymbolName: "arrow.down.circle.fill", accessibilityDescription: nil)
            menu.addItem(item)
            menu.addItem(.separator())
        }

        if !Permissions.hasScreenRecording {
            let item = NSMenuItem(
                title: L.t("需要屏幕录制权限 · 点此授权", "Screen Recording permission needed"),
                action: #selector(openScreenRecording), keyEquivalent: ""
            )
            item.target = self
            item.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil)
            menu.addItem(item)
            menu.addItem(.separator())
        }

        addItem(
            title: L.t("画中画前台窗口", "PiP Frontmost Window"),
            hint: prefs.pipHotkey.enabled ? prefs.pipHotkey.displayString : nil,
            symbol: "pip.enter",
            action: #selector(pipFrontmost)
        )
        addItem(
            title: L.t("区域捕获…", "Capture Region…"),
            hint: prefs.regionHotkey.enabled ? prefs.regionHotkey.displayString : nil,
            symbol: "dashed.rectangle",
            action: #selector(captureRegion)
        )

        let windowsItem = NSMenuItem(title: L.t("选择窗口", "Choose Window"), action: nil, keyEquivalent: "")
        windowsItem.image = NSImage(systemSymbolName: "macwindow.on.rectangle", accessibilityDescription: nil)
        windowsItem.submenu = windowsMenu
        menu.addItem(windowsItem)
        populateWindowsMenu()

        if store.hasSessions {
            menu.addItem(.separator())
            let header = NSMenuItem(
                title: L.t("活动浮窗（\(store.sessions.count)）", "Active PiP (\(store.sessions.count))"),
                action: nil, keyEquivalent: ""
            )
            header.isEnabled = false
            menu.addItem(header)

            for session in store.sessions {
                let suffix: String
                if session.isHidden {
                    suffix = L.t("（已隐藏）", " (hidden)")
                } else if session.isPaused {
                    suffix = L.t("（已暂停）", " (paused)")
                } else {
                    suffix = ""
                }

                // 父项挂子菜单：这是自动隐藏（点击穿透）之后最保底的操作出口
                let item = NSMenuItem(title: "  \(session.title)\(suffix)", action: nil, keyEquivalent: "")
                item.submenu = makeSessionSubmenu(for: session)
                menu.addItem(item)

                // ⌥ 替代项：按住 ⌥ 时父项变成「关闭」，保留 v0.1.0 的快捷行为
                let alternate = NSMenuItem(
                    title: L.t("  关闭：\(session.title)", "  Close: \(session.title)"),
                    action: #selector(sessionClose(_:)), keyEquivalent: ""
                )
                alternate.target = self
                alternate.representedObject = session.id
                alternate.keyEquivalentModifierMask = .option
                alternate.isAlternate = true
                menu.addItem(alternate)
            }

            addItem(
                title: store.allPaused ? L.t("全部继续", "Resume All") : L.t("全部暂停", "Pause All"),
                hint: nil,
                symbol: store.allPaused ? "play.fill" : "pause.fill",
                action: #selector(togglePauseAll)
            )
            addItem(
                title: L.t("关闭全部浮窗", "Close All"),
                hint: prefs.closeAllHotkey.enabled ? prefs.closeAllHotkey.displayString : nil,
                symbol: "xmark.circle",
                action: #selector(closeAll)
            )
        }

        menu.addItem(.separator())
        addItem(title: L.t("设置…", "Settings…"), hint: nil, symbol: "gearshape",
                action: #selector(openSettings))
        addItem(title: L.t("检查更新…", "Check for Updates…"), hint: nil, symbol: "arrow.down.circle",
                action: #selector(checkUpdates))
        menu.addItem(.separator())
        addItem(title: L.t("退出 MyWindowPip", "Quit MyWindowPip"), hint: "⌘Q", symbol: "power",
                action: #selector(quit))
    }

    private func populateWindowsMenu() {
        windowsMenu.removeAllItems()

        guard !cachedGroups.isEmpty else {
            let item = NSMenuItem(title: L.t("正在读取窗口列表…", "Loading windows…"),
                                  action: nil, keyEquivalent: "")
            item.isEnabled = false
            windowsMenu.addItem(item)
            return
        }

        for group in cachedGroups {
            let header = NSMenuItem(title: group.appName, action: nil, keyEquivalent: "")
            header.isEnabled = false
            if let icon = group.icon {
                let small = icon.copy() as? NSImage
                small?.size = NSSize(width: 14, height: 14)
                header.image = small
            }
            windowsMenu.addItem(header)

            for window in group.windows {
                let title = ShareableContentStore.shared.displayTitle(for: window)
                let item = NSMenuItem(title: "  \(title)", action: #selector(pipWindow(_:)),
                                      keyEquivalent: "")
                item.target = self
                item.representedObject = NSNumber(value: window.windowID)
                if store.session(windowID: window.windowID) != nil {
                    item.state = .on   // 已经有浮窗
                }
                windowsMenu.addItem(item)
            }
            windowsMenu.addItem(.separator())
        }
        if windowsMenu.items.last?.isSeparatorItem == true {
            windowsMenu.removeItem(at: windowsMenu.numberOfItems - 1)
        }
    }

    private func addItem(title: String, hint: String?, symbol: String, action: Selector) {
        let fullTitle = hint == nil ? title : "\(title)　\(hint!)"
        let item = NSMenuItem(title: fullTitle, action: action, keyEquivalent: "")
        item.target = self
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        menu.addItem(item)
    }

    // MARK: - 每会话子菜单

    /// 单个浮窗的操作子菜单。开了自动隐藏（点击穿透）后浮窗点不到，这里是保底出口。
    private func makeSessionSubmenu(for session: PiPSession) -> NSMenu {
        let submenu = NSMenu()
        let id = session.id
        let state = session.state

        submenu.addItem(sessionItem(
            title: session.isHidden ? L.t("显示浮窗", "Show window") : L.t("显示到最前", "Bring to front"),
            action: #selector(activateSession(_:)), payload: id
        ))
        submenu.addItem(sessionItem(
            title: session.isPaused ? L.t("继续", "Resume") : L.t("暂停", "Pause"),
            action: #selector(sessionTogglePause(_:)), payload: id
        ))

        submenu.addItem(.separator())

        let autoHide = sessionItem(title: L.t("自动隐藏（移入时淡出并点击穿透）",
                                             "Auto-hide (fade out & click-through)"),
                                   action: #selector(sessionToggleAutoHide(_:)), payload: id)
        autoHide.state = state.autoHide ? .on : .off
        submenu.addItem(autoHide)

        let idle = sessionItem(title: L.t("静止检测（画面不变时降到 1 fps）",
                                         "Idle detection (drop to 1 fps when static)"),
                               action: #selector(sessionToggleIdle(_:)), payload: id)
        idle.state = state.idleDetection ? .on : .off
        submenu.addItem(idle)

        // 透明度（全局偏好，5% 一档）
        let opacityItem = NSMenuItem(title: L.t("自动隐藏透明度（全局）", "Auto-hide opacity (global)"),
                                     action: nil, keyEquivalent: "")
        let opacityMenu = NSMenu()
        let current = Preferences.nearestOpacityStep(Preferences.shared.autoHideOpacity)
        for step in Preferences.autoHideOpacitySteps {
            let item = NSMenuItem(title: Preferences.opacityLabel(step),
                                  action: #selector(sessionSetOpacity(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = OpacityPayload(sessionID: id, opacity: step)
            item.state = abs(step - current) < 0.001 ? .on : .off
            opacityMenu.addItem(item)
        }
        opacityItem.submenu = opacityMenu
        submenu.addItem(opacityItem)

        // 帧率
        let fpsItem = NSMenuItem(title: L.t("帧率", "Frame rate"), action: nil, keyEquivalent: "")
        let fpsMenu = NSMenu()
        for step in FPSStep.allCases {
            let item = NSMenuItem(title: step.label, action: #selector(sessionSetFPS(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = FPSPayload(sessionID: id, fps: step)
            item.state = step == state.fps ? .on : .off
            fpsMenu.addItem(item)
        }
        fpsItem.submenu = fpsMenu
        submenu.addItem(fpsItem)

        submenu.addItem(.separator())
        submenu.addItem(sessionItem(title: L.t("关闭此浮窗", "Close this window"),
                                    action: #selector(sessionClose(_:)), payload: id))

        let hint = NSMenuItem(title: L.t("提示：淡出后按住 ⌥ 可临时唤回浮窗",
                                        "Tip: hold ⌥ to peek while faded"),
                              action: nil, keyEquivalent: "")
        hint.isEnabled = false
        submenu.addItem(hint)
        return submenu
    }

    private func sessionItem(title: String, action: Selector, payload: Any) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.representedObject = payload
        return item
    }

    private struct FPSPayload {
        let sessionID: UUID
        let fps: FPSStep
    }

    private struct OpacityPayload {
        let sessionID: UUID
        let opacity: CGFloat
    }

    // MARK: - Actions

    @objc private func pipFrontmost() { store.pipFrontmostWindow() }

    @objc private func captureRegion() { store.beginRegionCapture() }

    @objc private func pipWindow(_ sender: NSMenuItem) {
        guard let number = sender.representedObject as? NSNumber else { return }
        let windowID = CGWindowID(number.uint32Value)
        if let existing = store.session(windowID: windowID) {
            existing.bringToFront()
            existing.flashHighlight()
            return
        }
        ShareableContentStore.shared.window(id: windowID) { [weak self] window in
            guard let window else { return }
            self?.store.pip(window: window)
        }
    }

    @objc private func activateSession(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID,
              let session = store.session(id: id) else { return }
        if NSEvent.modifierFlags.contains(.option) {
            session.close()
            return
        }
        if session.isHidden { session.toggleHidden() }
        if session.isPaused { session.setPaused(false) }
        session.bringToFront()
        session.flashHighlight()
    }

    @objc private func sessionTogglePause(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID,
              let session = store.session(id: id) else { return }
        session.setPaused(!session.isPaused)
    }

    @objc private func sessionToggleAutoHide(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID,
              let session = store.session(id: id) else { return }
        session.toggleAutoHide()
    }

    @objc private func sessionToggleIdle(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID,
              let session = store.session(id: id) else { return }
        session.toggleIdleDetection()
    }

    @objc private func sessionSetFPS(_ sender: NSMenuItem) {
        guard let payload = sender.representedObject as? FPSPayload,
              let session = store.session(id: payload.sessionID) else { return }
        session.setFPS(payload.fps)
    }

    @objc private func sessionSetOpacity(_ sender: NSMenuItem) {
        guard let payload = sender.representedObject as? OpacityPayload,
              let session = store.session(id: payload.sessionID) else { return }
        session.setAutoHideOpacity(payload.opacity)
    }

    @objc private func sessionClose(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID,
              let session = store.session(id: id) else { return }
        session.close()
    }

    @objc private func togglePauseAll() { store.setAllPaused(!store.allPaused) }

    @objc private func closeAll() { store.closeAll() }

    @objc private func openSettings() { SettingsWindowController.shared.show() }

    @objc private func checkUpdates() { Updater.checkInteractive() }

    @objc private func showUpdate() {
        guard let info = pendingUpdate else { return }
        Updater.presentUpdate(info)
    }

    @objc private func openScreenRecording() { Permissions.ensureScreenRecording() }

    @objc private func quit() { NSApp.terminate(nil) }
}
