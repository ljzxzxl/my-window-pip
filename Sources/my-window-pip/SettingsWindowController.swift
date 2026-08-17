import AppKit

/// 设置窗口：通用 / 热键 / 增强模式 / 关于。
/// 全部用代码构建（无 xib），改动即时生效。
final class SettingsWindowController: NSObject, NSWindowDelegate {
    static let shared = SettingsWindowController()

    /// 浮窗展示方式变化后需要应用到已打开的浮窗
    var onLevelModeChanged: ((WindowLevelMode) -> Void)?
    /// 自动隐藏透明度变化后需要应用到已打开的浮窗
    var onAutoHideOpacityChanged: ((CGFloat) -> Void)?

    private var window: NSWindow?
    private var hotkeyStatusLabel: NSTextField?
    private var accessibilityStatusLabel: NSTextField?
    private var clickToActivateHint: NSTextField?
    private var enhancedCheckbox: NSButton?
    private var launchAtLoginCheckbox: NSButton?

    private let prefs = Preferences.shared

    private override init() { super.init() }

    // MARK: - 展示

    func show() {
        if let window {
            refreshDynamicStates()
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }

        let tabView = NSTabView(frame: NSRect(x: 0, y: 0, width: 460, height: 330))
        tabView.addTabViewItem(makeTab(L.t("通用", "General"), view: makeGeneralView()))
        tabView.addTabViewItem(makeTab(L.t("热键", "Hotkeys"), view: makeHotkeyView()))
        tabView.addTabViewItem(makeTab(L.t("增强模式", "Enhanced"), view: makeEnhancedView()))
        tabView.addTabViewItem(makeTab(L.t("关于", "About"), value: makeAboutView()))

        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 360),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered, defer: false
        )
        w.title = L.t("MyWindowPip 设置", "MyWindowPip Settings")
        w.delegate = self
        w.isReleasedWhenClosed = false
        w.center()

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 360))
        tabView.frame = container.bounds.insetBy(dx: 10, dy: 10)
        tabView.autoresizingMask = [.width, .height]
        container.addSubview(tabView)
        w.contentView = container

        window = w
        refreshDynamicStates()
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        // 保留实例，下次直接复用
    }

    // MARK: - 通用页

    private func makeGeneralView() -> NSView {
        let stack = verticalStack()

        let fpsPopup = NSPopUpButton()
        for step in FPSStep.allCases { fpsPopup.addItem(withTitle: step.label) }
        fpsPopup.selectItem(at: FPSStep.allCases.firstIndex(of: prefs.defaultFPS) ?? 3)
        fpsPopup.target = self
        fpsPopup.action = #selector(defaultFPSChanged(_:))
        stack.addArrangedSubview(row(L.t("默认帧率", "Default frame rate"), fpsPopup))

        let levelPopup = NSPopUpButton()
        for mode in WindowLevelMode.allCases { levelPopup.addItem(withTitle: mode.label) }
        levelPopup.selectItem(at: WindowLevelMode.allCases.firstIndex(of: prefs.windowLevelMode) ?? 0)
        levelPopup.target = self
        levelPopup.action = #selector(levelModeChanged(_:))
        stack.addArrangedSubview(row(L.t("悬浮方式", "PiP behavior"), levelPopup))

        stack.addArrangedSubview(checkbox(
            L.t("新建浮窗默认开启自动隐藏（鼠标移上去淡出并可点透）",
                "New PiP windows start with auto-hide enabled"),
            on: prefs.autoHideDefault, action: #selector(autoHideChanged(_:))
        ))

        let opacityPopup = NSPopUpButton()
        for step in Preferences.autoHideOpacitySteps {
            opacityPopup.addItem(withTitle: Preferences.opacityLabel(step))
        }
        let currentOpacity = Preferences.nearestOpacityStep(prefs.autoHideOpacity)
        opacityPopup.selectItem(at: Preferences.autoHideOpacitySteps.firstIndex(where: {
            abs($0 - currentOpacity) < 0.001
        }) ?? 6)
        opacityPopup.target = self
        opacityPopup.action = #selector(autoHideOpacityChanged(_:))
        stack.addArrangedSubview(row(L.t("自动隐藏后的不透明度", "Opacity while faded out"), opacityPopup))
        stack.addArrangedSubview(checkbox(
            L.t("默认开启静止检测（画面不变时自动降到 1 fps）",
                "Enable idle detection by default (drops to 1 fps when static)"),
            on: prefs.idleDetectionDefault, action: #selector(idleChanged(_:))
        ))
        stack.addArrangedSubview(checkbox(
            L.t("在浮窗中显示鼠标指针", "Show the mouse cursor inside PiP"),
            on: prefs.showsCursor, action: #selector(showsCursorChanged(_:))
        ))
        stack.addArrangedSubview(checkbox(
            L.t("单击浮窗切换到源应用窗口", "Click a PiP window to switch to its source app"),
            on: prefs.clickToActivateSource, action: #selector(clickToActivateChanged(_:))
        ))

        // 未授予辅助功能时只做非模态说明：不弹权限框是本项目一贯的约定
        let clickHint = hint(L.t(
            "未授予辅助功能权限时，单击浮窗只能激活源应用，由应用自己决定显示哪个窗口；"
                + "要精确切到被捕获的那个窗口，请在「增强模式」标签页里开启辅助功能权限。",
            "Without Accessibility, clicking a PiP can only activate the source app, which decides "
                + "which window to show. Grant Accessibility in the Enhanced tab to raise the exact window."
        ))
        clickToActivateHint = clickHint
        stack.addArrangedSubview(clickHint)

        let loginBox = checkbox(
            L.t("登录时自动启动", "Launch at login"),
            on: LoginItem.isEnabled, action: #selector(launchAtLoginChanged(_:))
        )
        launchAtLoginCheckbox = loginBox
        stack.addArrangedSubview(loginBox)

        stack.addArrangedSubview(hint(L.t(
            "帧率建议：看终端/日志 1–5 fps；看仪表盘 10–15 fps；看视频 30–60 fps。\n"
                + "自动隐藏淡出后浮窗会点击穿透，此时按住 ⌥ 可临时唤回，或从菜单栏的浮窗子菜单里关掉。",
            "Suggested: 1–5 fps for terminals and logs, 10–15 fps for dashboards, 30–60 fps for video.\n"
                + "A faded PiP window is click-through — hold ⌥ to peek, or turn auto-hide off from its menu bar submenu."
        )))
        return wrap(stack)
    }

    // MARK: - 热键页

    private func makeHotkeyView() -> NSView {
        let stack = verticalStack()

        let pipRecorder = HotkeyRecorderView(config: prefs.pipHotkey)
        pipRecorder.onChange = { [weak self] cfg in
            self?.prefs.pipHotkey = cfg
            self?.reloadHotkeys()
        }
        stack.addArrangedSubview(row(L.t("画中画前台窗口", "PiP frontmost window"), pipRecorder))

        let regionRecorder = HotkeyRecorderView(config: prefs.regionHotkey)
        regionRecorder.onChange = { [weak self] cfg in
            self?.prefs.regionHotkey = cfg
            self?.reloadHotkeys()
        }
        stack.addArrangedSubview(row(L.t("区域捕获", "Region capture"), regionRecorder))

        let closeRecorder = HotkeyRecorderView(config: prefs.closeAllHotkey)
        closeRecorder.onChange = { [weak self] cfg in
            self?.prefs.closeAllHotkey = cfg
            self?.reloadHotkeys()
        }
        stack.addArrangedSubview(row(L.t("关闭全部浮窗", "Close all PiP windows"), closeRecorder))

        let reset = NSButton(title: L.t("恢复默认", "Restore defaults"), target: self,
                             action: #selector(resetHotkeys))
        reset.bezelStyle = .rounded
        stack.addArrangedSubview(reset)

        let status = label("", size: 11, secondary: true)
        hotkeyStatusLabel = status
        stack.addArrangedSubview(status)

        stack.addArrangedSubview(hint(L.t(
            "点按输入框后按下组合键即可修改；⌫ 清除，⎋ 取消。需要 fn 组合键请开启增强模式。",
            "Click a field and press the combination; ⌫ clears, ⎋ cancels. For fn-based hotkeys, enable Enhanced mode."
        )))
        return wrap(stack)
    }

    // MARK: - 增强模式页

    private func makeEnhancedView() -> NSView {
        let stack = verticalStack()

        let box = checkbox(
            L.t("启用增强模式（需要辅助功能权限）", "Enable enhanced mode (requires Accessibility)"),
            on: prefs.enhancedMode, action: #selector(enhancedModeChanged(_:))
        )
        enhancedCheckbox = box
        stack.addArrangedSubview(box)

        let status = label("", size: 11, secondary: true)
        accessibilityStatusLabel = status
        let openButton = NSButton(title: L.t("打开系统设置", "Open System Settings"),
                                  target: self, action: #selector(openAccessibilitySettings))
        openButton.bezelStyle = .rounded
        stack.addArrangedSubview(rowView([status, openButton]))

        stack.addArrangedSubview(hint(L.t(
            """
            增强模式提供两类零权限模式做不到的操作：
            · fn 组合热键：fn + P 画中画前台窗口，fn + ⇧ + P 区域捕获
            · 鼠标悬停在浮窗上时的裸键：= / - 调倍率，F 切帧率，D 切静止检测，⌫ 关闭，轻点 fn 显隐

            注意：悬停按键会在鼠标位于浮窗范围内时拦截上述按键，其余按键一律原样透传。
            不开启增强模式时，全部操作都可通过热键、浮窗上的控制条与右键菜单完成。
            """,
            """
            Enhanced mode adds two things the permission-free mode cannot do:
            · fn-based hotkeys: fn + P for the frontmost window, fn + ⇧ + P for region capture
            · Hover keys: = / - zoom, F frame rate, D idle detection, ⌫ close, tap fn to hide/show

            Note: hover keys are only intercepted while the pointer is inside a PiP window; all other \
            keystrokes pass through untouched. Without enhanced mode, every action is still available \
            via hotkeys, the overlay controls and the right-click menu.
            """
        )))
        return wrap(stack)
    }

    // MARK: - 关于页

    private func makeAboutView() -> NSView {
        let stack = verticalStack()
        stack.addArrangedSubview(label("MyWindowPip \(Updater.currentVersion)", size: 15, bold: true))
        stack.addArrangedSubview(label(L.t("macOS 任意窗口画中画", "Picture-in-Picture for any macOS window"),
                                       size: 12, secondary: true))

        let checkButton = NSButton(title: L.t("检查更新…", "Check for Updates…"),
                                   target: self, action: #selector(checkUpdates))
        checkButton.bezelStyle = .rounded
        let repoButton = NSButton(title: L.t("项目主页", "Project page"),
                                  target: self, action: #selector(openRepo))
        repoButton.bezelStyle = .rounded
        stack.addArrangedSubview(rowView([checkButton, repoButton]))

        stack.addArrangedSubview(hint(L.t(
            """
            许可证：MIT。基于系统 ScreenCaptureKit 实现，画面只在本机内存中流转，
            不写入磁盘、不上传；除主动检查更新外不发起任何网络请求。
            """,
            """
            MIT licensed. Built on the system ScreenCaptureKit framework: frames stay in local memory, \
            are never written to disk or uploaded, and the app makes no network requests other than \
            update checks you trigger.
            """
        )))
        return wrap(stack)
    }

    // MARK: - 动态状态

    private func refreshDynamicStates() {
        let failed = HotkeyManager.shared.failedActions
        if failed.isEmpty {
            hotkeyStatusLabel?.stringValue = L.t("全部热键注册成功", "All hotkeys registered")
            hotkeyStatusLabel?.textColor = .secondaryLabelColor
        } else {
            hotkeyStatusLabel?.stringValue = L.t(
                "有 \(failed.count) 组热键被其它应用占用，请更换",
                "\(failed.count) hotkey(s) are taken by another app"
            )
            hotkeyStatusLabel?.textColor = .systemOrange
        }

        let granted = Permissions.hasAccessibility
        accessibilityStatusLabel?.stringValue = granted
            ? L.t("辅助功能权限：已授权", "Accessibility: granted")
            : L.t("辅助功能权限：未授权", "Accessibility: not granted")
        accessibilityStatusLabel?.textColor = granted ? .secondaryLabelColor : .systemOrange
        clickToActivateHint?.isHidden = granted || !prefs.clickToActivateSource
        enhancedCheckbox?.state = EventTapManager.shared.isEnabled ? .on : .off
        launchAtLoginCheckbox?.state = LoginItem.isEnabled ? .on : .off
    }

    private func reloadHotkeys() {
        HotkeyManager.shared.reload()
        refreshDynamicStates()
    }

    // MARK: - Actions

    @objc private func defaultFPSChanged(_ sender: NSPopUpButton) {
        prefs.defaultFPS = FPSStep.allCases[max(0, sender.indexOfSelectedItem)]
    }

    @objc private func levelModeChanged(_ sender: NSPopUpButton) {
        let mode = WindowLevelMode.allCases[max(0, sender.indexOfSelectedItem)]
        prefs.windowLevelMode = mode
        onLevelModeChanged?(mode)
    }

    @objc private func autoHideChanged(_ sender: NSButton) {
        prefs.autoHideDefault = sender.state == .on
    }

    @objc private func autoHideOpacityChanged(_ sender: NSPopUpButton) {
        let index = max(0, min(sender.indexOfSelectedItem, Preferences.autoHideOpacitySteps.count - 1))
        let value = Preferences.autoHideOpacitySteps[index]
        prefs.autoHideOpacity = value
        onAutoHideOpacityChanged?(value)
    }

    @objc private func idleChanged(_ sender: NSButton) {
        prefs.idleDetectionDefault = sender.state == .on
    }

    @objc private func showsCursorChanged(_ sender: NSButton) {
        prefs.showsCursor = sender.state == .on
    }

    @objc private func clickToActivateChanged(_ sender: NSButton) {
        prefs.clickToActivateSource = sender.state == .on
        refreshDynamicStates()
    }

    @objc private func launchAtLoginChanged(_ sender: NSButton) {
        let want = sender.state == .on
        if LoginItem.set(want) {
            prefs.launchAtLogin = want
        } else {
            sender.state = want ? .off : .on
            let alert = NSAlert()
            alert.messageText = L.t("设置登录项失败", "Could not update login item")
            alert.informativeText = L.t(
                "ad-hoc 签名的 App 可能无法注册登录项。可改用「系统设置 → 通用 → 登录项」手动添加。",
                "Ad-hoc signed apps may not register as login items. Add it manually in System Settings → General → Login Items."
            )
            alert.runModal()
        }
    }

    @objc private func enhancedModeChanged(_ sender: NSButton) {
        let want = sender.state == .on
        if want {
            guard Permissions.hasAccessibility else {
                sender.state = .off
                Permissions.showAccessibilityGuide()
                refreshDynamicStates()
                return
            }
            prefs.enhancedMode = true
            if !EventTapManager.shared.enable() {
                prefs.enhancedMode = false
                sender.state = .off
            }
        } else {
            prefs.enhancedMode = false
            EventTapManager.shared.disable()
        }
        refreshDynamicStates()
    }

    @objc private func openAccessibilitySettings() {
        Permissions.openAccessibilitySettings()
    }

    @objc private func resetHotkeys() {
        prefs.resetHotkeys()
        reloadHotkeys()
        // 重建热键页以刷新录制控件显示
        window?.close()
        window = nil
        show()
    }

    @objc private func checkUpdates() { Updater.checkInteractive() }

    @objc private func openRepo() {
        guard let url = URL(string: "https://github.com/\(Updater.repo)") else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - 构建小工具

    private func makeTab(_ title: String, view: NSView) -> NSTabViewItem {
        let item = NSTabViewItem(identifier: title)
        item.label = title
        item.view = view
        return item
    }

    private func makeTab(_ title: String, value view: NSView) -> NSTabViewItem {
        makeTab(title, view: view)
    }

    private func verticalStack() -> NSStackView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }

    private func wrap(_ stack: NSStackView) -> NSView {
        let view = NSView()
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 18),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -18),
        ])
        return view
    }

    private func row(_ title: String, _ control: NSView) -> NSView {
        let text = label(title, size: 12)
        text.setContentCompressionResistancePriority(.required, for: .horizontal)
        return rowView([text, control])
    }

    private func rowView(_ views: [NSView]) -> NSView {
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.alignment = .centerY
        return stack
    }

    private func checkbox(_ title: String, on: Bool, action: Selector) -> NSButton {
        let button = NSButton(checkboxWithTitle: title, target: self, action: action)
        button.state = on ? .on : .off
        button.font = .systemFont(ofSize: 12)
        return button
    }

    private func label(_ text: String, size: CGFloat, bold: Bool = false,
                       secondary: Bool = false) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = bold ? .systemFont(ofSize: size, weight: .semibold) : .systemFont(ofSize: size)
        field.textColor = secondary ? .secondaryLabelColor : .labelColor
        return field
    }

    private func hint(_ text: String) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = .systemFont(ofSize: 11)
        field.textColor = .secondaryLabelColor
        field.isSelectable = false
        field.preferredMaxLayoutWidth = 400
        return field
    }
}
