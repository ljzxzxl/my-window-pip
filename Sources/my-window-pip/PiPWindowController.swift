import AVFoundation
import AppKit
import CoreMedia

// MARK: - 浮窗面板

/// 无边框 + nonactivating 的浮窗面板。
///
/// 默认 borderless 窗口无法成为 key window，这里放开，使 App 处于活动状态时
/// `PiPContentView` 能收到 `keyDown`；同时永不成为 main window，避免抢走主窗口语义。
private final class PiPPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

// MARK: - 根容器视图

/// 浮窗根视图：负责 10pt 圆角裁剪，以及「重复 PiP 同一窗口」时的高亮闪烁提示。
private final class PiPRootView: NSView {
    static let cornerRadius: CGFloat = 10

    private let highlightLayer = CALayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = Self.cornerRadius
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor.clear.cgColor

        highlightLayer.borderWidth = 3
        highlightLayer.borderColor = NSColor(calibratedRed: 0.29, green: 0.63, blue: 1, alpha: 1).cgColor
        highlightLayer.cornerRadius = Self.cornerRadius
        highlightLayer.opacity = 0
        highlightLayer.zPosition = 1000
        layer?.addSublayer(highlightLayer)
    }

    required init?(coder: NSCoder) {
        fatalError("PiPRootView 仅支持代码创建（本项目无 xib/storyboard）")
    }

    override func layout() {
        super.layout()
        highlightLayer.frame = bounds
        if highlightLayer.superlayer == nil { layer?.addSublayer(highlightLayer) }
    }

    /// 边框闪烁两次。
    func flash() {
        highlightLayer.removeAnimation(forKey: "flash")
        let anim = CABasicAnimation(keyPath: "opacity")
        anim.fromValue = 0.0
        anim.toValue = 1.0
        anim.duration = 0.16
        anim.autoreverses = true
        anim.repeatCount = 2
        anim.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        highlightLayer.add(anim, forKey: "flash")
    }
}

// MARK: - 浮窗控制器

/// 单个 PiP 浮窗的控制器：负责 NSPanel 的创建、层级、宽高比锁定、位置校正、
/// 三层视图叠放（内容 / 占位 / 控制条）、右键菜单，以及把交互回调桥接给会话层。
///
/// 与捕获层没有任何直接引用，全部经 `PiPWindowDelegate`（由 PiPSession 实现）中转。
final class PiPWindowController: NSObject, NSWindowDelegate, NSMenuDelegate {

    // MARK: - 常量

    /// 浮窗最小宽度（逻辑点）
    static let minWidth: CGFloat = 160
    /// 首个浮窗距屏幕可见区域边缘的内缩
    static let edgeInset: CGFloat = 24
    /// resize 回调的 debounce 时长
    private static let resizeDebounceInterval: TimeInterval = 0.25
    /// alpha 动画时长（§4.10）
    private static let alphaAnimationDuration: TimeInterval = 0.12

    // MARK: - 对外

    weak var delegate: PiPWindowDelegate?

    var window: NSPanel { panel }

    private(set) var runtimeState: SessionRuntimeState = .streaming

    /// 当前内容区逻辑尺寸（点）——会话层据此构造捕获配置
    var contentPointSize: CGSize { panel.contentRect(forFrameRect: panel.frame).size }

    /// 当前所在屏幕的 backingScaleFactor
    var backingScale: CGFloat { panel.screen?.backingScaleFactor ?? panel.backingScaleFactor }

    var frameOrigin: CGPoint { panel.frame.origin }

    /// 供 HoverMonitor 校验鼠标是否落在本浮窗上
    var isHoveringMouse: Bool {
        guard panel.isVisible else { return false }
        return panel.frame.contains(NSEvent.mouseLocation)
    }

    // MARK: - 内部状态

    private let panel: PiPPanel
    private let root = PiPRootView(frame: .zero)
    private let contentView = PiPContentView(frame: .zero)
    private let placeholder = PlaceholderView(frame: .zero)
    private let overlay = OverlayControlsView(frame: .zero)

    private(set) var aspect: CGSize
    private var titleText: String
    private var levelMode: WindowLevelMode
    /// 最近一次由 `update(state:)` 收到的状态（delegate 不可用时的兜底）
    private var lastState: PiPSessionState?

    private var resizeDebounce: DispatchWorkItem?
    private var lastReportedScale: CGFloat = 0
    private var screenObserver: NSObjectProtocol?

    // 右键菜单
    private let contextMenu = NSMenu()
    private let titleItem = NSMenuItem()
    private let pauseItem = NSMenuItem()
    private let zoomResetItem = NSMenuItem()
    private let autoHideItem = NSMenuItem()
    private let idleItem = NSMenuItem()
    private var fpsItems: [FPSStep: NSMenuItem] = [:]
    private var levelItems: [WindowLevelMode: NSMenuItem] = [:]

    // MARK: - 初始化

    /// - Parameters:
    ///   - aspect: 源画面宽高比
    ///   - initialWidth: 初始逻辑宽度（会被 clamp 到 `minWidth` 以上）
    ///   - origin: 可选的记忆位置（AppKit 全局坐标，左下原点）；为 nil 时用主屏右下角
    ///   - cascadeIndex: 已存在的浮窗数量，用于错位摆放（origin 为 nil 时生效）
    init(title: String, aspect: CGSize, initialWidth: CGFloat, origin: CGPoint?,
         levelMode: WindowLevelMode, cascadeIndex: Int = 0) {
        let safeAspect = Self.sanitized(aspect)
        self.aspect = safeAspect
        self.titleText = title
        self.levelMode = levelMode

        let frame = Self.initialFrame(aspect: safeAspect, width: initialWidth,
                                     origin: origin, cascadeIndex: cascadeIndex)
        panel = PiPPanel(
            contentRect: frame,
            styleMask: [.nonactivatingPanel, .borderless, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        super.init()

        configurePanel()
        buildViewHierarchy()
        buildMenu()
        setTitle(title)
        lastReportedScale = backingScale
        observeScreenParameters()
    }

    deinit {
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        resizeDebounce?.cancel()
    }

    /// 多浮窗错位：每多一个浮窗向左上偏移 32pt。
    static func cascadeOffset(index: Int) -> CGSize {
        let i = CGFloat(max(0, index))
        return CGSize(width: -32 * i, height: 32 * i)
    }

    private static func sanitized(_ aspect: CGSize) -> CGSize {
        guard aspect.width > 0, aspect.height > 0 else { return CGSize(width: 16, height: 9) }
        return aspect
    }

    private static func minSize(for aspect: CGSize) -> CGSize {
        CGSize(width: minWidth, height: max(90, (minWidth * aspect.height / aspect.width).rounded()))
    }

    private static func initialFrame(aspect: CGSize, width: CGFloat,
                                     origin: CGPoint?, cascadeIndex: Int) -> CGRect {
        let w = max(minWidth, width.rounded())
        let h = max(90, (w * aspect.height / aspect.width).rounded())
        let size = CGSize(width: w, height: h)

        if let origin {
            return Geo.constrainToVisibleScreens(CGRect(origin: origin, size: size))
        }
        // 默认：主屏右下角内缩 24pt，并按已有浮窗数量向左上错位
        let visible = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame
            ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let offset = cascadeOffset(index: cascadeIndex)
        let rect = CGRect(x: visible.maxX - edgeInset - size.width + offset.width,
                          y: visible.minY + edgeInset + offset.height,
                          width: size.width, height: size.height)
        return Geo.constrainToVisibleScreens(rect)
    }

    // MARK: - 面板配置

    private func configurePanel() {
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = false
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.sharingType = .none              // 防镜中镜：其它捕获工具（包括本 App）拿不到浮窗内容
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .utilityWindow
        panel.tabbingMode = .disallowed
        panel.acceptsMouseMovedEvents = true
        panel.aspectRatio = aspect             // 系统自动锁定宽高比缩放
        panel.minSize = Self.minSize(for: aspect)
        panel.level = levelMode.windowLevel
        panel.collectionBehavior = levelMode.collectionBehavior
        panel.delegate = self
    }

    private func buildViewHierarchy() {
        panel.contentView = root

        // 叠放次序：内容在下 → 占位居中 → 控制条最上
        contentView.frame = root.bounds
        contentView.autoresizingMask = [.width, .height]
        root.addSubview(contentView)

        placeholder.frame = root.bounds
        placeholder.autoresizingMask = [.width, .height]
        root.addSubview(placeholder)

        // 控制条是贴在顶部的一条 bar（它自带 [.width, .minYMargin] 的 autoresizing）
        overlay.frame = Self.overlayFrame(in: root.bounds)
        root.addSubview(overlay)

        placeholder.setVisible(false, animated: false)
        overlay.setVisible(false, animated: false)

        // 占位视图上的「打开系统设置」按钮（缺权限时才出现）
        placeholder.onOpenSettings = { Permissions.openScreenRecordingSettings() }

        // 手势回调 → delegate（窗口层不做任何状态决策）
        contentView.onRequestZoom = { [weak self] zoom, anchor in
            self?.delegate?.pipRequestZoom(zoom, anchor: anchor)
        }
        contentView.onRequestPan = { [weak self] delta in
            self?.delegate?.pipRequestPan(by: delta)
        }
        contentView.onRequestZoomReset = { [weak self] in self?.delegate?.pipRequestZoomReset() }
        contentView.onRequestClose = { [weak self] in self?.delegate?.pipRequestClose() }
        contentView.onRequestCycleFPS = { [weak self] in self?.cycleFPS() }
        contentView.onRequestToggleIdleDetection = { [weak self] in
            self?.delegate?.pipRequestToggleIdleDetection()
        }
        contentView.onRequestTogglePause = { [weak self] in self?.delegate?.pipRequestTogglePause() }

        overlay.onClose = { [weak self] in self?.delegate?.pipRequestClose() }
        overlay.onCycleFPS = { [weak self] in self?.cycleFPS() }
        overlay.onResetZoom = { [weak self] in self?.delegate?.pipRequestZoomReset() }
        overlay.onToggleAutoHide = { [weak self] in self?.delegate?.pipRequestToggleAutoHide() }
        overlay.onToggleIdleDetection = { [weak self] in self?.delegate?.pipRequestToggleIdleDetection() }
        overlay.onTogglePause = { [weak self] in self?.delegate?.pipRequestTogglePause() }

        contentView.update(aspect: aspect)
    }

    /// 控制条位置：贴浮窗顶部，左右与顶部各内缩 6pt。
    private static func overlayFrame(in bounds: CGRect) -> CGRect {
        let inset: CGFloat = 6
        let height = OverlayControlsView.preferredHeight
        return CGRect(x: bounds.minX + inset,
                      y: max(bounds.minY, bounds.maxY - inset - height),
                      width: max(0, bounds.width - inset * 2),
                      height: min(height, bounds.height))
    }

    private func observeScreenParameters() {
        // 显示器拔插 / 分辨率变化：把浮窗收回可见区域，并按新 scale 重新出流
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.handleScreenParametersChange()
        }
    }

    // MARK: - 生命周期

    func show() {
        panel.orderFrontRegardless()
        _ = panel.makeFirstResponder(contentView)
        refreshMenu()
    }

    func close() {
        resizeDebounce?.cancel()
        resizeDebounce = nil
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
            self.screenObserver = nil
        }
        contentView.flushAndReset()
        panel.delegate = nil
        panel.orderOut(nil)
        panel.close()          // isReleasedWhenClosed = false，安全
    }

    // MARK: - 帧渲染

    /// 主线程调用。
    func enqueue(_ sampleBuffer: CMSampleBuffer) {
        guard panel.isVisible else { return }   // 完全隐藏时无需送帧
        contentView.enqueue(sampleBuffer)
    }

    // MARK: - 状态同步

    func update(state: PiPSessionState) {
        lastState = state
        contentView.update(state: state, aspect: aspect)
        overlay.update(state: state)
        // 占位视图只在非 streaming 时可见，避免每次状态刷新都跑一次淡出动画
        if runtimeState != .streaming {
            placeholder.update(runtimeState: runtimeState, source: state.source)
        }
        refreshMenu()
    }

    func update(runtimeState newState: SessionRuntimeState) {
        let changed = newState != runtimeState
        runtimeState = newState
        if let source = currentState?.source {
            // PlaceholderView.update 内部会同步自身可见性
            placeholder.update(runtimeState: newState, source: source)
        } else {
            // 还没拿到 source（会话层尚未 update(state:)）：至少把显隐切对
            placeholder.setVisible(newState != .streaming, animated: changed)
        }
        // 终态才清画面：暂停 / 等待源 / 重连时保留最后一帧（占位是半透明蒙版，看起来像"冻帧"）
        switch newState {
        case .sourceLost, .permissionDenied, .failed:
            contentView.flushAndReset()
        case .streaming, .paused, .waitingForSource, .reconnecting:
            break
        }
        refreshMenu()
    }

    func setTitle(_ title: String) {
        titleText = title
        panel.title = title
        overlay.titleText = title
        titleItem.title = title
    }

    /// 源尺寸变化时更新宽高比：保持当前宽度与左上角位置，重算高度。
    func setAspect(_ newAspect: CGSize) {
        let safe = Self.sanitized(newAspect)
        guard abs(safe.width / safe.height - aspect.width / aspect.height) > 0.0001 else { return }
        aspect = safe
        panel.aspectRatio = safe
        panel.minSize = Self.minSize(for: safe)
        contentView.update(aspect: safe)

        var frame = panel.frame
        let newHeight = max(Self.minSize(for: safe).height, (frame.width * safe.height / safe.width).rounded())
        guard abs(newHeight - frame.height) > 0.5 else { return }
        frame.origin.y = frame.maxY - newHeight
        frame.size.height = newHeight
        panel.setFrame(Geo.constrainToVisibleScreens(frame), display: true)
        scheduleResizeNotify()
    }

    func setLevelMode(_ mode: WindowLevelMode) {
        levelMode = mode
        panel.level = mode.windowLevel
        panel.collectionBehavior = mode.collectionBehavior
        refreshMenu()
    }

    /// 点击穿透（自动隐藏时用）。
    func setClickThrough(_ enabled: Bool) {
        panel.ignoresMouseEvents = enabled
    }

    func setAlpha(_ alpha: CGFloat, animated: Bool) {
        let target = min(max(alpha, 0), 1)
        guard animated else {
            panel.alphaValue = target
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.alphaAnimationDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            self.panel.animator().alphaValue = target
        }
    }

    /// 悬停控制条的显隐（由会话层 / HoverMonitor 驱动）。
    func setControlsVisible(_ visible: Bool, animated: Bool = true) {
        overlay.setVisible(visible, animated: animated)
    }

    // MARK: - 显隐与前置

    func hideCompletely() {
        resizeDebounce?.cancel()
        resizeDebounce = nil
        contentView.flushAndReset()
        panel.orderOut(nil)
    }

    func restoreFromHidden() {
        panel.alphaValue = 1
        panel.ignoresMouseEvents = false
        panel.orderFrontRegardless()
        _ = panel.makeFirstResponder(contentView)
    }

    func bringToFront() {
        panel.orderFrontRegardless()
    }

    /// 重复 PiP 同一窗口时的提示动效。
    func flashHighlight() {
        bringToFront()
        root.flash()
    }

    // MARK: - NSWindowDelegate

    func windowDidResize(_ notification: Notification) {
        scheduleResizeNotify()
    }

    func windowDidMove(_ notification: Notification) {
        delegate?.pipDidMove()
        notifyIfScaleChanged()
    }

    func windowDidChangeScreen(_ notification: Notification) {
        notifyIfScaleChanged()
    }

    func windowDidChangeBackingProperties(_ notification: Notification) {
        notifyIfScaleChanged()
    }

    // MARK: - resize / 跨屏

    private func scheduleResizeNotify() {
        resizeDebounce?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.notifyResize() }
        resizeDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.resizeDebounceInterval, execute: work)
    }

    private func notifyResize() {
        resizeDebounce = nil
        lastReportedScale = backingScale
        delegate?.pipDidResize(pointSize: contentPointSize, scale: lastReportedScale)
    }

    /// 跨屏导致 backingScaleFactor 变化时，也要重算输出像素（§6 多屏）。
    private func notifyIfScaleChanged() {
        let scale = backingScale
        guard abs(scale - lastReportedScale) > 0.01 else { return }
        Log.debug("浮窗跨屏，scale \(lastReportedScale) → \(scale)")
        resizeDebounce?.cancel()
        resizeDebounce = nil
        notifyResize()
    }

    private func handleScreenParametersChange() {
        let corrected = Geo.constrainToVisibleScreens(panel.frame)
        if corrected != panel.frame {
            panel.setFrame(corrected, display: true)
            delegate?.pipDidMove()
        }
        notifyIfScaleChanged()
    }

    // MARK: - 右键菜单（零权限模式下的完整操作入口）

    private var currentState: PiPSessionState? { delegate?.currentSessionState ?? lastState }

    private func buildMenu() {
        contextMenu.autoenablesItems = false
        contextMenu.delegate = self

        titleItem.title = titleText
        titleItem.isEnabled = false
        contextMenu.addItem(titleItem)
        contextMenu.addItem(.separator())

        pauseItem.title = L.t("暂停", "Pause")
        pauseItem.target = self
        pauseItem.action = #selector(menuTogglePause)
        contextMenu.addItem(pauseItem)

        zoomResetItem.title = L.t("复位缩放", "Reset Zoom")
        zoomResetItem.target = self
        zoomResetItem.action = #selector(menuResetZoom)
        contextMenu.addItem(zoomResetItem)

        let fpsItem = NSMenuItem(title: L.t("帧率", "Frame Rate"), action: nil, keyEquivalent: "")
        let fpsMenu = NSMenu()
        fpsMenu.autoenablesItems = false
        for step in FPSStep.allCases {
            let item = NSMenuItem(title: step.label, action: #selector(menuPickFPS(_:)), keyEquivalent: "")
            item.target = self
            item.tag = step.rawValue
            fpsMenu.addItem(item)
            fpsItems[step] = item
        }
        fpsItem.submenu = fpsMenu
        contextMenu.addItem(fpsItem)

        contextMenu.addItem(.separator())

        autoHideItem.title = L.t("自动隐藏（鼠标移入时穿透）", "Auto-hide (click-through on hover)")
        autoHideItem.target = self
        autoHideItem.action = #selector(menuToggleAutoHide)
        contextMenu.addItem(autoHideItem)

        idleItem.title = L.t("静止检测（画面不变时降帧）", "Idle detection (drop FPS when static)")
        idleItem.target = self
        idleItem.action = #selector(menuToggleIdleDetection)
        contextMenu.addItem(idleItem)

        let levelItem = NSMenuItem(title: L.t("置顶层级", "Window Level"), action: nil, keyEquivalent: "")
        let levelMenu = NSMenu()
        levelMenu.autoenablesItems = false
        for mode in WindowLevelMode.allCases {
            let item = NSMenuItem(title: mode.label, action: #selector(menuPickLevel(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = mode.rawValue
            levelMenu.addItem(item)
            levelItems[mode] = item
        }
        levelItem.submenu = levelMenu
        contextMenu.addItem(levelItem)

        contextMenu.addItem(.separator())

        let closeItem = NSMenuItem(title: L.t("关闭此浮窗", "Close This PiP"),
                                   action: #selector(menuClose), keyEquivalent: "")
        closeItem.target = self
        contextMenu.addItem(closeItem)

        // 三层视图都挂同一份菜单，保证任意位置右键都能唤出
        root.menu = contextMenu
        contentView.menu = contextMenu
        placeholder.menu = contextMenu
        overlay.menu = contextMenu
    }

    private func refreshMenu() {
        let state = currentState
        titleItem.title = state?.source.displayTitle ?? titleText

        let paused = state?.isPaused ?? false
        pauseItem.title = paused ? L.t("继续", "Resume") : L.t("暂停", "Pause")

        let zoom = state?.zoom ?? 1
        zoomResetItem.title = zoom > 1.01
            ? L.t("复位缩放（当前 \(String(format: "%.1f", zoom))×）",
                  "Reset Zoom (now \(String(format: "%.1f", zoom))×)")
            : L.t("复位缩放", "Reset Zoom")
        zoomResetItem.isEnabled = zoom > 1.01

        autoHideItem.state = (state?.autoHide ?? false) ? .on : .off
        idleItem.state = (state?.idleDetection ?? true) ? .on : .off

        let fps = state?.fps ?? Preferences.shared.defaultFPS
        for (step, item) in fpsItems { item.state = (step == fps) ? .on : .off }
        for (mode, item) in levelItems { item.state = (mode == levelMode) ? .on : .off }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === contextMenu else { return }
        refreshMenu()
    }

    // MARK: - 菜单动作

    @objc private func menuClose() {
        delegate?.pipRequestClose()
    }

    @objc private func menuTogglePause() {
        delegate?.pipRequestTogglePause()
    }

    @objc private func menuResetZoom() {
        delegate?.pipRequestZoomReset()
    }

    @objc private func menuPickFPS(_ sender: NSMenuItem) {
        guard let step = FPSStep(rawValue: sender.tag) else { return }
        delegate?.pipRequestFPS(step)
    }

    @objc private func menuToggleAutoHide() {
        delegate?.pipRequestToggleAutoHide()
    }

    @objc private func menuToggleIdleDetection() {
        delegate?.pipRequestToggleIdleDetection()
    }

    /// 层级是纯窗口关注点，会话层协议里没有对应回调：这里就地生效并写回全局偏好。
    @objc private func menuPickLevel(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let mode = WindowLevelMode(rawValue: raw) else { return }
        setLevelMode(mode)
        Preferences.shared.windowLevelMode = mode
    }

    private func cycleFPS() {
        let current = currentState?.fps ?? Preferences.shared.defaultFPS
        delegate?.pipRequestFPS(current.next())
    }
}
