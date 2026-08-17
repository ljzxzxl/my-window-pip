import AppKit

/// 浮窗内容区之上的占位视图：源不可用 / 暂停 / 重连 / 出错时盖住画面并说明当前状况。
///
/// 约定（对应设计文档 §4.13「生命周期与错误恢复」）：
/// - 只负责「显示」，不做任何决策：不请求权限、不重连、不关闭会话，全部由会话层驱动。
/// - `update(runtimeState:source:)` 会顺带切换自身可见性（`.streaming` 时隐藏）。
/// - 除可选操作按钮外，`hitTest` 一律返回 nil：占位期间仍可拖动浮窗、点按浮窗继续播放。
final class PlaceholderView: NSView {

    /// 可选：缺少屏幕录制权限时，是否显示「打开系统设置」按钮。
    /// 为 nil 则只显示文案（本视图刻意不直接依赖 Permissions）。
    var onOpenSettings: (() -> Void)?

    // MARK: - 尺寸常量

    private enum Metrics {
        static let iconBox: CGFloat = 34
        static let iconPointSize: CGFloat = 28
        static let titleFontSize: CGFloat = 13
        static let subtitleFontSize: CGFloat = 11
        static let spacing: CGFloat = 6
        static let horizontalPadding: CGFloat = 12
        static let fade: TimeInterval = 0.12
        /// 低于此高度时藏掉副标题，再低则只留标题（浮窗可能被拉得很小）
        static let subtitleMinHeight: CGFloat = 92
        static let iconMinHeight: CGFloat = 56
    }

    // MARK: - 子视图

    private let iconView = SpinningIconView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let actionButton = NSButton()
    private let stack = NSStackView()

    /// 当前渲染的运行态，用于决定是否需要旋转动画
    private var runtimeState: SessionRuntimeState = .streaming
    /// 内容是否希望显示副标题 / 操作按钮（与「因为太小而藏起来」区分开）
    private var wantsSubtitle = false
    private var wantsActionButton = false
    private var desiredVisible = false

    // MARK: - 初始化

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        // 深色蒙版，强制暗色外观让 labelColor / secondaryLabelColor 解析成浅色
        appearance = NSAppearance(named: .darkAqua)
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.72).cgColor
        autoresizingMask = [.width, .height]
        alphaValue = 0
        isHidden = true

        setupSubviews()
        setAccessibilityRole(.group)
        setAccessibilityLabel(L.t("浮窗状态提示", "Overlay status"))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("PlaceholderView 为纯代码视图，不支持 xib / storyboard 加载")
    }

    private func setupSubviews() {
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.contentTintColor = .labelColor
        iconView.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = .systemFont(ofSize: Metrics.titleFontSize, weight: .medium)
        titleLabel.textColor = .labelColor
        titleLabel.alignment = .center
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.usesSingleLineMode = true

        subtitleLabel.font = .systemFont(ofSize: Metrics.subtitleFontSize)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.alignment = .center
        subtitleLabel.usesSingleLineMode = false
        subtitleLabel.lineBreakMode = .byWordWrapping
        subtitleLabel.maximumNumberOfLines = 3
        subtitleLabel.cell?.truncatesLastVisibleLine = true

        actionButton.bezelStyle = .rounded
        actionButton.controlSize = .small
        actionButton.font = .systemFont(ofSize: Metrics.subtitleFontSize)
        actionButton.target = self
        actionButton.action = #selector(handleAction)
        actionButton.isHidden = true

        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = Metrics.spacing
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.setViews([iconView, titleLabel, subtitleLabel, actionButton], in: .leading)
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor,
                                           constant: Metrics.horizontalPadding),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor,
                                            constant: -Metrics.horizontalPadding),
            iconView.widthAnchor.constraint(equalToConstant: Metrics.iconBox),
            iconView.heightAnchor.constraint(equalToConstant: Metrics.iconBox),
        ])
    }

    // MARK: - 状态渲染

    /// 按运行态渲染图标 / 文案，并同步自身可见性（`.streaming` 时整体隐藏）。
    func update(runtimeState: SessionRuntimeState, source: CaptureSource) {
        self.runtimeState = runtimeState

        guard runtimeState != .streaming else {
            setVisible(false, animated: true)
            return
        }

        let content = Self.content(for: runtimeState, source: source)
        apply(content)
        setVisible(true, animated: true)
    }

    /// 一屏占位内容。
    private struct Content {
        var symbols: [String]
        var title: String
        var subtitle: String
        /// 图标是否用警示色
        var isAlert: Bool = false
        /// 是否需要持续旋转（重连）
        var spins: Bool = false
        /// 操作按钮标题，nil 表示不显示
        var actionTitle: String?
    }

    private static func content(for state: SessionRuntimeState, source: CaptureSource) -> Content {
        switch state {
        case .streaming:
            // 调用方已提前返回；保留分支保证 switch 穷尽
            return Content(symbols: ["pause.circle"], title: "", subtitle: "")

        case .paused:
            return Content(
                symbols: ["pause.circle"],
                title: L.t("已暂停", "Paused"),
                subtitle: L.t("点按浮窗或控制条继续", "Click the window or the controls to resume")
            )

        case .waitingForSource:
            return Content(
                symbols: ["arrow.down.right.and.arrow.up.left.circle",
                          "arrow.down.right.and.arrow.up.left"],
                title: L.t("源窗口暂不可见", "Source window unavailable"),
                subtitle: L.t("切回窗口所在 Space 或取消最小化后会自动继续",
                              "Switch to its Space or restore it to resume automatically")
            )

        case let .reconnecting(attempt):
            return Content(
                symbols: ["arrow.triangle.2.circlepath"],
                title: L.t("正在重连…（第 \(attempt) 次）", "Reconnecting… (attempt \(attempt))"),
                subtitle: L.t("正在重新连接「\(source.displayTitle)」",
                              "Trying to reattach to \(source.displayTitle)"),
                spins: true
            )

        case .sourceLost:
            return Content(
                symbols: ["xmark.circle"],
                title: L.t("源窗口已关闭", "Source window closed"),
                subtitle: L.t("「\(source.displayTitle)」已不可用，浮窗即将关闭",
                              "\(source.displayTitle) is no longer available. This window will close shortly."),
                isAlert: true
            )

        case .permissionDenied:
            return Content(
                symbols: ["lock.circle"],
                title: L.t("缺少屏幕录制权限", "Screen Recording permission required"),
                subtitle: L.t("在「系统设置 → 隐私与安全性 → 屏幕录制与系统录音」里打开 MyWindowPip 的开关，然后重启本应用",
                              "Turn MyWindowPip on in System Settings → Privacy & Security → Screen & System Audio Recording, then relaunch"),
                isAlert: true,
                actionTitle: L.t("打开系统设置", "Open System Settings")
            )

        case let .failed(message):
            let detail = message.trimmingCharacters(in: .whitespacesAndNewlines)
            return Content(
                symbols: ["exclamationmark.triangle"],
                title: L.t("捕获失败", "Capture failed"),
                subtitle: detail.isEmpty
                    ? L.t("「\(source.displayTitle)」的画面无法继续获取",
                          "Cannot keep capturing \(source.displayTitle)")
                    : detail,
                isAlert: true
            )
        }
    }

    private func apply(_ content: Content) {
        iconView.image = Self.symbolImage(content.symbols, accessibility: content.title)
        iconView.contentTintColor = content.isAlert ? .systemOrange : .labelColor

        titleLabel.stringValue = content.title

        subtitleLabel.stringValue = content.subtitle
        wantsSubtitle = !content.subtitle.isEmpty

        // 操作按钮：仅当外部注入了回调时才出现，避免点了没反应
        if let actionTitle = content.actionTitle, onOpenSettings != nil {
            actionButton.title = actionTitle
            actionButton.setAccessibilityLabel(actionTitle)
            wantsActionButton = true
        } else {
            wantsActionButton = false
        }

        setAccessibilityLabel([content.title, content.subtitle]
            .filter { !$0.isEmpty }.joined(separator: "，"))

        needsLayout = true
        syncSpinning()
    }

    // MARK: - 布局

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    override func layout() {
        super.layout()

        // 换行宽度必须手动喂给 NSTextField，否则多行文案量不出高度
        let wrapWidth = max(80, bounds.width - Metrics.horizontalPadding * 2)
        if abs(subtitleLabel.preferredMaxLayoutWidth - wrapWidth) > 0.5 {
            subtitleLabel.preferredMaxLayoutWidth = wrapWidth
        }

        // 浮窗可能很小，按可用高度逐级裁掉次要元素
        let compactSubtitle = bounds.height < Metrics.subtitleMinHeight
        let compactIcon = bounds.height < Metrics.iconMinHeight
        iconView.isHidden = compactIcon
        subtitleLabel.isHidden = !wantsSubtitle || compactSubtitle
        actionButton.isHidden = !wantsActionButton || compactSubtitle
    }

    // MARK: - 显示 / 隐藏

    /// 120ms 淡入淡出；淡出结束后置 `isHidden = true` 并停掉旋转动画，避免空转耗电。
    func setVisible(_ visible: Bool, animated: Bool) {
        desiredVisible = visible
        if visible { isHidden = false }
        syncSpinning()

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

    /// 只有「可见 + 重连中 + 已上屏」三者同时成立才转。
    private func syncSpinning() {
        var spins = false
        if case .reconnecting = runtimeState { spins = true }
        if spins && desiredVisible && window != nil {
            iconView.startSpinning()
        } else {
            iconView.stopSpinning()
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        syncSpinning()
    }

    // MARK: - 命中测试

    /// 除操作按钮外全部放行：占位期间仍可拖动浮窗、点按浮窗继续。
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, alphaValue > 0.05 else { return nil }
        guard !actionButton.isHidden else { return nil }
        let local = convert(point, from: superview)
        let buttonRect = actionButton.convert(actionButton.bounds, to: self)
        return buttonRect.insetBy(dx: -2, dy: -2).contains(local) ? actionButton : nil
    }

    override var mouseDownCanMoveWindow: Bool { false }

    @objc private func handleAction() { onOpenSettings?() }

    // MARK: - SF Symbol

    private static let symbolConfiguration = NSImage.SymbolConfiguration(
        pointSize: Metrics.iconPointSize, weight: .regular
    )

    /// 按候选顺序取第一个本机存在的 SF Symbol（低版本 macOS 上作降级）。
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

// MARK: - 可旋转图标

/// 支持持续旋转的图标视图。旋转只在需要时开启，不可见时必须停掉（省电）。
private final class SpinningIconView: NSImageView {
    private static let animationKey = "mwp.spin"
    private var isSpinning = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("SpinningIconView 为纯代码视图，不支持 xib / storyboard 加载")
    }

    override func layout() {
        super.layout()
        // 自动布局改完 frame 后重新钉住中心点，保证绕自身中心旋转
        guard let layer else { return }
        layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        layer.bounds = CGRect(origin: .zero, size: frame.size)
        layer.position = CGPoint(x: frame.midX, y: frame.midY)
    }

    func startSpinning() {
        guard !isSpinning, let layer else { return }
        isSpinning = true
        layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        layer.position = CGPoint(x: frame.midX, y: frame.midY)

        let rotation = CABasicAnimation(keyPath: "transform.rotation.z")
        rotation.fromValue = 0
        rotation.toValue = -Double.pi * 2   // 负值 = 顺时针（AppKit 非翻转坐标）
        rotation.duration = 1.1
        rotation.repeatCount = .infinity
        rotation.isRemovedOnCompletion = false
        layer.add(rotation, forKey: Self.animationKey)
    }

    func stopSpinning() {
        guard isSpinning else { return }
        isSpinning = false
        layer?.removeAnimation(forKey: Self.animationKey)
    }
}
