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

// MARK: - 浮窗内提示条

/// 画在浮窗自己视图树里的提示条（替代系统 tooltip）。
///
/// 为什么不用系统 tooltip：浮窗 level 为 `.screenSaver`(1000)，而系统 tooltip 是层级更低的独立窗口，
/// 会被压在浮窗后面只露出窗外的一小截；它的初始延迟也由 `NSToolTipManager` 私有控制，无法调整。
/// 自绘的提示条与浮窗同属一个窗口，既没有层级问题，出现时机也完全自主。
private final class HintLabel: NSView {
    /// 圆角
    private static let cornerRadius: CGFloat = 6
    /// 文字左右 / 上下内边距
    private static let hInset: CGFloat = 7
    private static let vInset: CGFloat = 4
    private static let font = NSFont.systemFont(ofSize: 11)

    private let label = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = Self.cornerRadius
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.82).cgColor
        alphaValue = 0
        isHidden = true

        label.font = Self.font
        label.textColor = .white
        label.alignment = .left
        label.usesSingleLineMode = true
        label.lineBreakMode = .byTruncatingTail
        label.cell?.truncatesLastVisibleLine = true
        label.drawsBackground = false
        addSubview(label)
    }

    required init?(coder: NSCoder) {
        fatalError("HintLabel 仅支持代码创建（本项目无 xib/storyboard）")
    }

    var text: String = "" {
        didSet {
            guard text != oldValue else { return }
            label.stringValue = text
            needsLayout = true
        }
    }

    /// 单行渲染所需尺寸；超过 `maxWidth` 时按 `maxWidth` 收口，文字交给尾部截断处理。
    static func preferredSize(for text: String, maxWidth: CGFloat) -> CGSize {
        let measured = (text as NSString).size(withAttributes: [.font: font])
        let width = min(ceil(measured.width) + hInset * 2, max(0, maxWidth))
        return CGSize(width: width, height: ceil(measured.height) + vInset * 2)
    }

    override func layout() {
        super.layout()
        label.frame = bounds.insetBy(dx: Self.hInset, dy: Self.vInset)
    }

    /// 绝不参与命中测试：浮窗拖动、滚轮缩放平移、双击复位等手势必须原样落到下层内容视图。
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
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
    /// 提示条与控制条之间的垂直间隙
    private static let hintGap: CGFloat = 4
    /// 提示条相对内容区的安全内缩（clamp 用）
    private static let hintEdgeInset: CGFloat = 6
    private static let hintFadeInDuration: TimeInterval = 0.08
    private static let hintFadeOutDuration: TimeInterval = 0.12
    /// 低于该不透明度视为「自动隐藏淡出态」，此时不打扰用户
    private static let hintMinWindowAlpha: CGFloat = 0.99

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
    private let hint = HintLabel(frame: .zero)

    private(set) var aspect: CGSize
    private var titleText: String
    private var levelMode: WindowLevelMode
    /// 最近一次由 `update(state:)` 收到的状态（delegate 不可用时的兜底）
    private var lastState: PiPSessionState?

    private var resizeDebounce: DispatchWorkItem?
    private var lastReportedScale: CGFloat = 0
    private var screenObserver: NSObjectProtocol?

    // 提示条状态
    /// 当前提示文案（nil = 未显示）
    private var hintText: String?
    /// 触发按钮在**控制条自身坐标系**内的 frame；nil 表示用默认位置（控制条正下方、右对齐）
    private var hintAnchor: CGRect?
    /// `duration` 到点自动淡出的定时器，重复调用 `showHint` 会打断它
    private var hintDismissWork: DispatchWorkItem?
    /// 最近一次 `setAlpha` 的目标值。淡出动画进行中读 `panel.alphaValue` 拿到的是中间值，
    /// 会误把「刚恢复不透明 + 立刻提示」判成淡出态，所以用目标值判定。
    private var alphaTarget: CGFloat = 1

    // 右键菜单
    private let contextMenu = NSMenu()
    private let titleItem = NSMenuItem()
    private let pauseItem = NSMenuItem()
    private let zoomResetItem = NSMenuItem()
    private let autoHideItem = NSMenuItem()
    private let idleItem = NSMenuItem()
    private var fpsItems: [FPSStep: NSMenuItem] = [:]
    private var levelItems: [WindowLevelMode: NSMenuItem] = [:]
    /// 自动隐藏透明度档位项（下标与 `Preferences.autoHideOpacitySteps` 一一对应）
    private var opacityItems: [NSMenuItem] = []

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
        hintDismissWork?.cancel()
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

        // 提示条压在控制条之上（位置每次显示时按锚点重算，不用 autoresizing）
        root.addSubview(hint, positioned: .above, relativeTo: overlay)

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

        // 控制条只上报「悬停了谁、该说什么」，提示条的定位与动画都在本控制器里
        overlay.onHintChange = { [weak self] payload in
            guard let self else { return }
            guard let payload else {
                self.showHint(nil, near: nil)
                return
            }
            self.showHint(payload.0, near: payload.1)
        }

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
        hintDismissWork?.cancel()
        hintDismissWork = nil
        hideHint(animated: false)
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
            self.screenObserver = nil
        }
        contentView.flushAndReset()
        panel.delegate = nil
        panel.orderOut(nil)
        panel.close()          // isReleasedWhenClosed = false，安全
    }

    // MARK: - 浮窗内提示条

    /// 在浮窗内显示提示条（不用系统 tooltip，避免被浮窗层级遮挡）。
    ///
    /// - Parameters:
    ///   - text: nil / 空串表示立即隐藏提示
    ///   - anchorInOverlay: 触发按钮在**控制条自身坐标系**内的 frame；nil 表示用默认位置
    ///     （控制条正下方、右对齐到控制条右边缘）
    ///   - duration: nil 表示常驻直到再次调用；否则到点自动淡出
    func showHint(_ text: String?, near anchorInOverlay: CGRect?, duration: TimeInterval? = nil) {
        // 无论如何都先掐掉上一条的自动淡出定时器，避免旧定时器把新提示带走
        hintDismissWork?.cancel()
        hintDismissWork = nil

        guard let text, !text.isEmpty else {
            hideHint(animated: true)
            return
        }
        // 淡出态（自动隐藏中）或窗口没显示时不打扰：此时提示条本身也几乎看不清
        guard panel.isVisible, alphaTarget > Self.hintMinWindowAlpha else {
            hideHint(animated: false)
            return
        }

        // 已经完全显示时只换文案与位置，不再重跑淡入（控制条每次 layout 都会重发当前提示）
        let wasFullyVisible = !hint.isHidden && hint.alphaValue > 0.999
        hintText = text
        hintAnchor = anchorInOverlay
        hint.text = text
        hint.isHidden = false
        layoutHint()
        if !wasFullyVisible { fadeHint(to: 1, duration: Self.hintFadeInDuration) }

        guard let duration, duration > 0 else { return }
        let work = DispatchWorkItem { [weak self] in
            self?.hintDismissWork = nil
            self?.hideHint(animated: true)
        }
        hintDismissWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }

    private func hideHint(animated: Bool) {
        hintDismissWork?.cancel()
        hintDismissWork = nil
        hintText = nil
        hintAnchor = nil

        guard animated, !hint.isHidden, hint.alphaValue > 0 else {
            hint.alphaValue = 0
            hint.isHidden = true
            return
        }
        fadeHint(to: 0, duration: Self.hintFadeOutDuration) { [weak self] in
            // 淡出期间又来了新提示（hintText 非 nil）就别再藏
            guard let self, self.hintText == nil else { return }
            self.hint.isHidden = true
        }
    }

    /// 淡入 80ms / 淡出 120ms。新的动画会直接接管进行中的旧动画。
    private func fadeHint(to alpha: CGFloat, duration: TimeInterval,
                          completion: (() -> Void)? = nil) {
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            self.hint.animator().alphaValue = alpha
        }, completionHandler: completion)
    }

    /// 定位策略：紧贴控制条下方 `hintGap`，右边缘对齐到锚点右边缘（换算到 root 坐标系），
    /// 整体 clamp 在 root 内缩 `hintEdgeInset` 的范围内；窗口很窄时宽度先 clamp，文字交给尾部截断。
    private func layoutHint() {
        guard let text = hintText, !text.isEmpty else { return }
        let available = root.bounds.insetBy(dx: Self.hintEdgeInset, dy: Self.hintEdgeInset)
        guard available.width > 1, available.height > 1 else {
            hint.frame = .zero
            return
        }

        let size = HintLabel.preferredSize(for: text, maxWidth: available.width)
        let bar = Self.overlayFrame(in: root.bounds)
        // 锚点在控制条坐标系内，控制条是 root 的直接子视图，加上它的原点即为 root 坐标
        let anchorRight = hintAnchor.map { bar.minX + $0.maxX } ?? bar.maxX

        var x = anchorRight - size.width
        x = min(max(x, available.minX), max(available.minX, available.maxX - size.width))
        var y = bar.minY - Self.hintGap - size.height
        y = min(max(y, available.minY), max(available.minY, available.maxY - size.height))

        hint.frame = CGRect(x: x.rounded(), y: y.rounded(), width: size.width, height: size.height)
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
        alphaTarget = target
        // 进入淡出态时提示条一起收掉（此时它本身也看不清，留着只会挡画面）
        if target <= Self.hintMinWindowAlpha { hideHint(animated: false) }
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
        hideHint(animated: false)
        contentView.flushAndReset()
        panel.orderOut(nil)
    }

    func restoreFromHidden() {
        panel.alphaValue = 1
        alphaTarget = 1
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
        // 窗口尺寸变了：提示条要按新的内容区重新 clamp（控制条自己走 autoresizing）
        layoutHint()
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

        // 自动隐藏透明度：5% 一档，作用域是全局偏好（标题里已标注「全局」）
        let opacityItem = NSMenuItem(title: L.t("自动隐藏透明度（全局）", "Auto-hide opacity (global)"),
                                     action: nil, keyEquivalent: "")
        let opacityMenu = NSMenu()
        opacityMenu.autoenablesItems = false
        for (index, step) in Preferences.autoHideOpacitySteps.enumerated() {
            let item = NSMenuItem(title: Preferences.opacityLabel(step),
                                  action: #selector(menuPickAutoHideOpacity(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            opacityMenu.addItem(item)
            opacityItems.append(item)
        }
        opacityMenu.addItem(.separator())
        // 逃生通道说明：淡出后浮窗是点击穿透的，按住 ⌥ 才能临时唤回来操作
        let peekNote = NSMenuItem(title: L.t("淡出后按住 ⌥ 可临时唤回浮窗", "Hold ⌥ to peek while faded"),
                                  action: nil, keyEquivalent: "")
        peekNote.isEnabled = false
        opacityMenu.addItem(peekNote)
        opacityItem.submenu = opacityMenu
        contextMenu.addItem(opacityItem)

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

        // 透明度勾选：把当前偏好对齐到最近的 5% 档位再比对
        let opacity = Preferences.nearestOpacityStep(Preferences.shared.autoHideOpacity)
        for (index, item) in opacityItems.enumerated() {
            let step = Preferences.autoHideOpacitySteps[index]
            item.state = abs(step - opacity) < 0.001 ? .on : .off
        }

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

    /// 透明度是全局偏好，写入与「对已淡出浮窗立即生效」都由会话层负责
    @objc private func menuPickAutoHideOpacity(_ sender: NSMenuItem) {
        guard Preferences.autoHideOpacitySteps.indices.contains(sender.tag) else { return }
        delegate?.pipRequestAutoHideOpacity(Preferences.autoHideOpacitySteps[sender.tag])
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
