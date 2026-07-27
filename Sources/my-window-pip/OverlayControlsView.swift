import AppKit

/// 浮窗顶部的悬浮控制条：毛玻璃底 + 左侧标题（可选倍率标签）+ 右侧一排小图标按钮。
///
/// 交互约定（对应设计文档 §4.10「点击穿透与自动隐藏」）：
/// - 只有落在「可用按钮」上的点击才被本视图接收；标题与空白区域的 `hitTest` 返回 nil，
///   让事件穿到下层内容视图，从而保留浮窗拖动、滚轮平移等手势。
/// - 显示/隐藏统一走 `setVisible(_:animated:)`；淡出结束后置 `isHidden = true`，彻底不拦截鼠标。
/// - 本视图只发信号（闭包回调），不持有会话、不改状态；状态一律由 `update(state:)` 单向灌入。
final class OverlayControlsView: NSView {

    // MARK: - 对外回调

    /// 关闭按钮
    var onClose: (() -> Void)?
    /// 帧率按钮（循环切换到下一档）
    var onCycleFPS: (() -> Void)?
    /// 复位缩放按钮
    var onResetZoom: (() -> Void)?
    /// 自动隐藏开关
    var onToggleAutoHide: (() -> Void)?
    /// 静止检测开关
    var onToggleIdleDetection: (() -> Void)?
    /// 暂停 / 继续
    var onTogglePause: (() -> Void)?

    // MARK: - 对外状态

    /// 左侧标题，形如 `Terminal · npm run build`。单行、尾部省略。
    var titleText: String = "" {
        didSet {
            guard titleText != oldValue else { return }
            titleLabel.stringValue = titleText
            titleLabel.toolTip = titleText.isEmpty ? nil : titleText
            needsLayout = true
        }
    }

    /// 控制条建议高度，供窗口控制器摆放使用。
    static let preferredHeight: CGFloat = Metrics.height

    // MARK: - 尺寸常量

    private enum Metrics {
        static let height: CGFloat = 30
        static let cornerRadius: CGFloat = 8
        /// 图标按钮边长
        static let button: CGFloat = 20
        /// 按钮间距
        static let gap: CGFloat = 4
        /// 右侧内边距
        static let trailingInset: CGFloat = 6
        /// 左侧标题内边距
        static let leadingInset: CGFloat = 8
        /// 淡入淡出时长
        static let fade: TimeInterval = 0.12
        /// 图标符号字号
        static let symbolPointSize: CGFloat = 11
    }

    // MARK: - 颜色

    /// 开关处于「开」时的高亮色
    private static var activeTint: NSColor { .controlAccentColor }
    /// 常态（次要灰）
    private static var inactiveTint: NSColor { .secondaryLabelColor }
    /// 不可用
    private static var disabledTint: NSColor { .tertiaryLabelColor }

    // MARK: - 子视图

    private let backdrop = NSVisualEffectView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let zoomLabel = NSTextField(labelWithString: "")

    private let pauseButton = NSButton()
    private let fpsButton = NSButton()
    private let resetZoomButton = NSButton()
    private let autoHideButton = NSButton()
    private let idleButton = NSButton()
    private let closeButton = NSButton()

    /// 从右到左的摆放顺序（视觉从左到右为：暂停 / 帧率 / 复位 / 自动隐藏 / 静止检测 / 关闭）
    private var buttonsRightToLeft: [NSButton] {
        [closeButton, idleButton, autoHideButton, resetZoomButton, fpsButton, pauseButton]
    }

    /// `setVisible` 的目标态，避免淡出回调把刚重新显示的控制条又藏起来
    private var desiredVisible = false

    // MARK: - 初始化

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        // HUD 材质本就是暗色，强制暗色外观让语义色（次要灰 / 标签色）在浅色系统下同样清晰
        appearance = NSAppearance(named: .darkAqua)
        // 贴在浮窗顶部：跟随宽度变化，与顶边保持固定距离
        autoresizingMask = [.width, .minYMargin]
        alphaValue = 0
        isHidden = true

        setupBackdrop()
        setupLabels()
        setupButtons()
        setupAccessibility()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("OverlayControlsView 为纯代码视图，不支持 xib / storyboard 加载")
    }

    private func setupBackdrop() {
        backdrop.material = .hudWindow
        backdrop.blendingMode = .withinWindow
        backdrop.state = .active
        backdrop.wantsLayer = true
        backdrop.layer?.cornerRadius = Metrics.cornerRadius
        backdrop.layer?.masksToBounds = true
        backdrop.autoresizingMask = [.width, .height]
        addSubview(backdrop)
    }

    private func setupLabels() {
        titleLabel.font = .systemFont(ofSize: 11)
        titleLabel.textColor = Self.inactiveTint
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.usesSingleLineMode = true
        titleLabel.cell?.truncatesLastVisibleLine = true
        titleLabel.alignment = .left
        addSubview(titleLabel)

        // 倍率标签：等宽数字，避免 1.0× → 10.0× 时抖动
        zoomLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .medium)
        zoomLabel.textColor = Self.activeTint
        zoomLabel.usesSingleLineMode = true
        zoomLabel.isHidden = true
        zoomLabel.toolTip = L.t("当前放大倍率", "Current zoom factor")
        addSubview(zoomLabel)
    }

    private func setupButtons() {
        configureIconButton(
            pauseButton, symbols: ["pause.fill"],
            tooltip: L.t("暂停", "Pause"),
            accessibility: L.t("暂停", "Pause"),
            action: #selector(handleTogglePause)
        )

        // 帧率按钮是文字按钮（如 15f），点一次循环到下一档
        fpsButton.isBordered = false
        fpsButton.setButtonType(.momentaryChange)
        fpsButton.imagePosition = .noImage
        fpsButton.target = self
        fpsButton.action = #selector(handleCycleFPS)
        fpsButton.refusesFirstResponder = true
        fpsButton.toolTip = L.t("切换帧率", "Cycle frame rate")
        fpsButton.setAccessibilityLabel(L.t("切换帧率", "Cycle frame rate"))
        addSubview(fpsButton)
        setFPSTitle("15f", color: Self.inactiveTint)

        configureIconButton(
            resetZoomButton, symbols: ["arrow.up.left.and.down.right.magnifyingglass"],
            tooltip: L.t("复位缩放", "Reset zoom"),
            accessibility: L.t("复位缩放", "Reset zoom"),
            action: #selector(handleResetZoom)
        )
        resetZoomButton.isEnabled = false
        resetZoomButton.contentTintColor = Self.disabledTint

        configureIconButton(
            autoHideButton, symbols: ["eye"],
            tooltip: L.t("自动隐藏（鼠标移入时淡出）", "Auto-hide (fade out on hover)"),
            accessibility: L.t("自动隐藏", "Auto-hide"),
            action: #selector(handleToggleAutoHide)
        )

        configureIconButton(
            idleButton, symbols: ["bolt.badge.clock", "zzz"],
            tooltip: L.t("静止检测（画面不变时自动降帧）", "Idle detection (drop frame rate when static)"),
            accessibility: L.t("静止检测", "Idle detection"),
            action: #selector(handleToggleIdleDetection)
        )

        configureIconButton(
            closeButton, symbols: ["xmark"],
            tooltip: L.t("关闭浮窗", "Close picture-in-picture"),
            accessibility: L.t("关闭浮窗", "Close picture-in-picture"),
            action: #selector(handleClose)
        )
    }

    private func setupAccessibility() {
        setAccessibilityRole(.group)
        setAccessibilityLabel(L.t("浮窗控制条", "Overlay controls"))
    }

    /// 统一配置图标按钮：无边框、模板着色、20×20、带 toolTip 与无障碍标签。
    private func configureIconButton(_ button: NSButton, symbols: [String],
                                     tooltip: String, accessibility: String,
                                     action: Selector) {
        button.isBordered = false
        button.setButtonType(.momentaryChange)
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
        button.image = Self.symbolImage(symbols, accessibility: accessibility)
        button.contentTintColor = Self.inactiveTint
        button.target = self
        button.action = action
        button.refusesFirstResponder = true
        button.toolTip = tooltip
        button.setAccessibilityLabel(accessibility)
        addSubview(button)
    }

    // MARK: - 布局

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        backdrop.frame = bounds

        let buttonY = ((bounds.height - Metrics.button) / 2).rounded()
        var x = bounds.maxX - Metrics.trailingInset

        for button in buttonsRightToLeft {
            let width = (button === fpsButton) ? fpsButtonWidth() : Metrics.button
            x -= width
            button.frame = CGRect(x: x.rounded(), y: buttonY, width: width, height: Metrics.button)
            x -= Metrics.gap
        }

        // x 此时是最左按钮左边再退一个 gap，正好作为文字区右界
        let textLeft = bounds.minX + Metrics.leadingInset
        let textRight = max(textLeft, x)
        let available = textRight - textLeft

        var zoomWidth: CGFloat = 0
        if !zoomLabel.isHidden {
            zoomWidth = min(ceil(zoomLabel.fittingSize.width) + 2, available)
        }
        let titleBudget = max(0, available - (zoomWidth > 0 ? zoomWidth + Metrics.gap : 0))
        let titleWidth = min(ceil(titleLabel.fittingSize.width), titleBudget)
        titleLabel.frame = CGRect(
            x: textLeft, y: verticalCenter(of: ceil(titleLabel.fittingSize.height)),
            width: titleWidth, height: ceil(titleLabel.fittingSize.height)
        )

        if zoomWidth > 0 {
            let h = ceil(zoomLabel.fittingSize.height)
            zoomLabel.frame = CGRect(
                x: titleLabel.frame.maxX + Metrics.gap, y: verticalCenter(of: h),
                width: zoomWidth, height: h
            )
        }
    }

    private func verticalCenter(of height: CGFloat) -> CGFloat {
        ((bounds.height - height) / 2).rounded()
    }

    /// 帧率文字按钮按内容取宽（"1f" ~ "60f"），最小 22pt 保证点击面积。
    private func fpsButtonWidth() -> CGFloat {
        let measured = ceil(fpsButton.attributedTitle.size().width) + 8
        return max(22, measured)
    }

    // MARK: - 状态刷新

    /// 用会话状态刷新控制条：帧率文字、暂停图标、开关高亮、复位可用性、倍率标签。
    func update(state: PiPSessionState) {
        // 帧率
        setFPSTitle("\(state.fps.rawValue)f", color: Self.inactiveTint)
        fpsButton.toolTip = L.t("帧率 \(state.fps.rawValue) fps，点按切换下一档",
                                "\(state.fps.rawValue) fps — click to cycle")
        fpsButton.setAccessibilityLabel(L.t("帧率 \(state.fps.rawValue) 帧每秒",
                                            "Frame rate \(state.fps.rawValue) fps"))

        // 暂停 / 继续
        pauseButton.image = Self.symbolImage(
            [state.isPaused ? "play.fill" : "pause.fill"],
            accessibility: state.isPaused ? L.t("继续", "Resume") : L.t("暂停", "Pause")
        )
        pauseButton.contentTintColor = state.isPaused ? Self.activeTint : Self.inactiveTint
        pauseButton.toolTip = state.isPaused ? L.t("继续", "Resume") : L.t("暂停", "Pause")
        pauseButton.setAccessibilityLabel(state.isPaused ? L.t("继续", "Resume") : L.t("暂停", "Pause"))

        // 复位缩放：仅放大状态可用
        let zoomed = state.zoom > 1.001
        resetZoomButton.isEnabled = zoomed
        resetZoomButton.contentTintColor = zoomed ? Self.inactiveTint : Self.disabledTint

        // 自动隐藏：开 → eye.slash（鼠标移入会淡出）
        autoHideButton.image = Self.symbolImage(
            [state.autoHide ? "eye.slash" : "eye"],
            accessibility: L.t("自动隐藏", "Auto-hide")
        )
        applyToggleStyle(
            autoHideButton, isOn: state.autoHide,
            onTooltip: L.t("自动隐藏：开（鼠标移入时淡出）", "Auto-hide: on (fades out on hover)"),
            offTooltip: L.t("自动隐藏：关", "Auto-hide: off"),
            onLabel: L.t("自动隐藏：开", "Auto-hide: on"),
            offLabel: L.t("自动隐藏：关", "Auto-hide: off")
        )

        // 静止检测
        applyToggleStyle(
            idleButton, isOn: state.idleDetection,
            onTooltip: L.t("静止检测：开（画面不变时自动降到 1 fps）",
                           "Idle detection: on (drops to 1 fps when static)"),
            offTooltip: L.t("静止检测：关", "Idle detection: off"),
            onLabel: L.t("静止检测：开", "Idle detection: on"),
            offLabel: L.t("静止检测：关", "Idle detection: off")
        )

        // 倍率标签
        if zoomed {
            zoomLabel.stringValue = String(format: "%.1f×", Double(state.zoom))
            zoomLabel.isHidden = false
        } else {
            zoomLabel.stringValue = ""
            zoomLabel.isHidden = true
        }

        needsLayout = true
    }

    private func applyToggleStyle(_ button: NSButton, isOn: Bool,
                                  onTooltip: String, offTooltip: String,
                                  onLabel: String, offLabel: String) {
        button.contentTintColor = isOn ? Self.activeTint : Self.inactiveTint
        button.toolTip = isOn ? onTooltip : offTooltip
        button.setAccessibilityLabel(isOn ? onLabel : offLabel)
    }

    private func setFPSTitle(_ text: String, color: NSColor) {
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        fpsButton.attributedTitle = NSAttributedString(string: text, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium),
            .foregroundColor: color,
            .paragraphStyle: style,
        ])
    }

    // MARK: - 显示 / 隐藏

    /// 120ms 淡入淡出。淡出结束后置 `isHidden = true`，保证不再参与命中测试。
    func setVisible(_ visible: Bool, animated: Bool) {
        desiredVisible = visible
        if visible { isHidden = false }

        guard animated else {
            alphaValue = visible ? 1 : 0
            isHidden = !visible
            return
        }

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = Metrics.fade
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            self.animator().alphaValue = visible ? 1 : 0
        }, completionHandler: { [weak self] in
            guard let self, !visible, !self.desiredVisible else { return }
            self.isHidden = true
        })
    }

    // MARK: - 命中测试（保住浮窗拖动）

    /// 只有落在「可见且可用」的按钮上才返回该按钮；标题与空白区域返回 nil，
    /// 事件因此落到下层内容视图（浮窗拖动 / 双击 / 滚轮缩放平移不受影响）。
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, alphaValue > 0.05 else { return nil }
        let local = convert(point, from: superview)
        guard bounds.contains(local) else { return nil }
        for button in buttonsRightToLeft where button.isEnabled && !button.isHidden {
            // 稍微放大命中区域，20pt 小按钮更好点
            if button.frame.insetBy(dx: -2, dy: -2).contains(local) { return button }
        }
        return nil
    }

    /// 控制条自身不承担窗口拖动（空白区域已经通过 hitTest 让给下层内容视图）。
    override var mouseDownCanMoveWindow: Bool { false }

    // MARK: - 按钮动作

    @objc private func handleClose() { onClose?() }
    @objc private func handleCycleFPS() { onCycleFPS?() }
    @objc private func handleResetZoom() { onResetZoom?() }
    @objc private func handleToggleAutoHide() { onToggleAutoHide?() }
    @objc private func handleToggleIdleDetection() { onToggleIdleDetection?() }
    @objc private func handleTogglePause() { onTogglePause?() }

    // MARK: - SF Symbol

    private static let symbolConfiguration = NSImage.SymbolConfiguration(
        pointSize: Metrics.symbolPointSize, weight: .semibold
    )

    /// 按候选顺序取第一个本机存在的 SF Symbol（低版本 macOS 上作降级），全都不存在时记一条告警。
    private static func symbolImage(_ names: [String], accessibility: String) -> NSImage? {
        for name in names {
            guard let image = NSImage(systemSymbolName: name, accessibilityDescription: accessibility) else {
                continue
            }
            let configured = image.withSymbolConfiguration(symbolConfiguration) ?? image
            configured.isTemplate = true
            return configured
        }
        Log.warn("SF Symbol 均不可用：\(names.joined(separator: " / "))")
        return nil
    }
}
