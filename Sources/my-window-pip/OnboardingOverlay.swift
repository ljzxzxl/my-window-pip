import AppKit

/// 引导浮层的尺寸与视觉常量。放在文件作用域（file-private），遮罩视图 / 卡片 / 箭头共用同一份。
private enum OnboardingMetrics {
    /// 遮罩黑色不透明度
    static let maskAlpha: CGFloat = 0.38

    /// 高亮孔相对菜单栏图标 frame 的外扩量
    static let holePadding: CGFloat = 6
    static let holeCornerRadius: CGFloat = 6
    static let holeStrokeWidth: CGFloat = 2
    /// 点击高亮孔的判定范围再放宽一点，手抖也能点到
    static let holeHitSlop: CGFloat = 4

    /// 描边呼吸动画：1.5s 一个周期，alpha 在 0.45…1.0 之间循环
    static let breathPeriod: CFTimeInterval = 1.5
    static let breathMinAlpha: CGFloat = 0.45
    static let breathMaxAlpha: CGFloat = 1.0
    static let breathTick: TimeInterval = 1.0 / 30

    /// 说明卡片
    static let cardWidth: CGFloat = 380
    static let cardCornerRadius: CGFloat = 12
    /// 卡片上缘与高亮孔下缘之间的距离
    static let cardGap: CGFloat = 90
    /// 卡片必须留在 `visibleFrame` 内缩这么多的范围里
    static let screenInset: CGFloat = 24

    /// 箭头
    static let arrowLineWidth: CGFloat = 2.5
    static let arrowHeadLength: CGFloat = 11
    static let arrowHeadHalfWidth: CGFloat = 5.5
    /// 曲线两端与高亮孔 / 卡片之间留出的空隙
    static let arrowGap: CGFloat = 6
    /// 曲线端点距卡片左右边缘的最小内缩，避免箭头从卡片圆角处冒出来
    static let arrowEdgeInset: CGFloat = 24

    /// 降级布局：卡片顶边距 `visibleFrame` 顶边的距离（给箭头留出空间）
    static let fallbackTopGap: CGFloat = 56
    /// 降级布局：箭头尖端距屏幕右上角的内缩
    static let fallbackTipInset: CGFloat = 34
}

/// 首次启动引导浮层。
///
/// 应用是 `LSUIElement`（无 Dock 图标、无主窗口），首次双击打开后用户只看到菜单栏多了个图标，
/// 很容易以为"没反应"。本浮层在每块屏幕上盖一层半透明遮罩，把菜单栏图标位置挖空成高亮孔，
/// 再用一条贝塞尔曲线箭头把视线引到说明卡片上，明确告诉用户「已经在后台运行了，从这个图标进入」。
///
/// 手法与 `RegionSelectionController` 保持一致：
/// - 每屏一个 borderless 遮罩窗口，`CGShieldingWindowLevel()` 层级（高于浮窗、提示条与菜单栏）
/// - `NSColor.clear` + `.copy` 混合把遮罩直接挖穿
/// - 遮罩窗口重写 `canBecomeKey`，否则收不到 `⎋`
///
/// 生命周期由 `OnboardingOverlay.current` 持有；所有关闭路径都汇总到 `close()`，用 `isFinished` 防重入。
final class OnboardingOverlay {

    // MARK: - 对外 API

    /// 当前正在展示的实例。nil 表示没有引导在屏上。
    private static var current: OnboardingOverlay?

    static var isVisible: Bool { current != nil }

    /// 展示引导浮层。重复调用时先关掉上一个（旧实例的 `onDismiss` 会照常回调）。
    /// - Parameters:
    ///   - anchor: 菜单栏图标在**屏幕坐标**（AppKit 左下原点）下的 frame；nil 表示拿不到位置，走降级布局
    ///   - onOpenMenu: 用户点了高亮孔或「打开菜单」按钮，调用方在此弹出状态栏菜单
    ///   - onDismiss: 引导关闭（无论哪种方式）时回调，调用方在此写 `hasSeenOnboarding`
    static func show(anchor: CGRect?,
                     onOpenMenu: @escaping () -> Void,
                     onDismiss: @escaping () -> Void) {
        dismiss()

        let overlay = OnboardingOverlay(anchor: anchor, onOpenMenu: onOpenMenu, onDismiss: onDismiss)
        guard overlay.present() else {
            // 一块屏幕都没有时也要把 onDismiss 兑现，否则调用方永远等不到「引导结束」
            onDismiss()
            return
        }
        current = overlay
    }

    static func dismiss() { current?.close() }

    // MARK: - 内部状态

    /// 已做过合法性校验的锚点（nil = 降级布局）
    private let anchor: CGRect?
    private var onOpenMenu: (() -> Void)?
    private var onDismiss: (() -> Void)?

    private var windows: [OnboardingOverlayWindow] = []
    private var maskViews: [OnboardingMaskView] = []

    /// 呼吸动画定时器（关闭时必须停掉，否则空转耗电）
    private var breathTimer: Timer?
    private var breathStart: CFTimeInterval = 0
    private var screenObserver: NSObjectProtocol?

    /// 关闭去重标志位：点孔 / 主按钮 / 知道了 / 点空白 / `⎋` / 屏幕变化都汇总到 `close()`，只生效一次
    private var isFinished = false

    private init(anchor: CGRect?,
                 onOpenMenu: @escaping () -> Void,
                 onDismiss: @escaping () -> Void) {
        self.anchor = Self.sanitize(anchor)
        self.onOpenMenu = onOpenMenu
        self.onDismiss = onDismiss
    }

    // MARK: - 展示

    /// 建窗上屏。返回 false 表示没有可用屏幕，调用方需要直接走 `onDismiss`。
    private func present() -> Bool {
        let screens = NSScreen.screens
        guard !screens.isEmpty else {
            Log.warn("引导浮层：没有可用屏幕，跳过展示")
            return false
        }

        let anchorScreen = anchor.flatMap { Self.screen(containing: $0) } ?? NSScreen.main ?? screens[0]
        var keyWindow: OnboardingOverlayWindow?

        for screen in screens {
            let mask = OnboardingMaskView(frame: CGRect(origin: .zero, size: screen.frame.size))
            mask.onDismiss = { [weak self] in self?.close() }

            // 只有图标所在那块屏画高亮孔、箭头与卡片；其余屏只有纯遮罩，点一下也能关
            if screen === anchorScreen {
                mask.onOpenMenu = { [weak self] in self?.openMenuThenClose() }
                configureGuidance(on: mask, screen: screen)
            }

            let window = OnboardingOverlayWindow(screen: screen, content: mask)
            window.orderFrontRegardless()
            windows.append(window)
            maskViews.append(mask)
            if screen === anchorScreen { keyWindow = window }
        }

        // 必须先激活自身进程再 makeKey，否则 LSUIElement 应用收不到键盘事件（`⎋` 会失效）
        NSApp.activate(ignoringOtherApps: true)
        if let keyWindow {
            keyWindow.makeKey()
            if let content = keyWindow.contentView {
                keyWindow.makeFirstResponder(content)
            }
        }

        startBreathing()
        observeScreenChanges()
        Log.info("引导浮层已展示，屏幕数 \(windows.count)，anchor=\(anchor.map { "\($0)" } ?? "nil（降级布局）")")
        return true
    }

    /// 在图标所在屏上摆好高亮孔、说明卡片与箭头。所有几何先在屏幕坐标里算，最后统一平移成视图坐标。
    private func configureGuidance(on mask: OnboardingMaskView, screen: NSScreen) {
        let card = OnboardingCardView(width: OnboardingMetrics.cardWidth)
        card.onPrimary = { [weak self] in self?.openMenuThenClose() }
        card.onSecondary = { [weak self] in self?.close() }

        // 视图坐标原点在屏幕左下角，减去屏幕 frame 的原点即可
        let shift = screen.frame.origin
        let limit = screen.visibleFrame.insetBy(dx: OnboardingMetrics.screenInset,
                                                dy: OnboardingMetrics.screenInset)
        let cardSize = card.frame.size

        var cardRect: CGRect
        var tip: CGPoint
        var hole: CGRect?

        if let anchor {
            // 高亮孔：以图标 frame 为中心外扩 6pt，并裁进屏幕内（图标贴着菜单栏顶边，外扩后可能越界）
            let punched = anchor.insetBy(dx: -OnboardingMetrics.holePadding,
                                        dy: -OnboardingMetrics.holePadding)
                .intersection(screen.frame)
            if !punched.isNull, punched.width > 2, punched.height > 2 {
                hole = punched
            }

            let holeRect = hole ?? anchor
            // 卡片：高亮孔正下方 90pt、水平与孔对齐，再 clamp 进 visibleFrame 内缩 24pt 的范围
            cardRect = CGRect(x: holeRect.midX - cardSize.width / 2,
                              y: holeRect.minY - OnboardingMetrics.cardGap - cardSize.height,
                              width: cardSize.width, height: cardSize.height)
            cardRect = Self.clamp(cardRect, in: limit)
            tip = CGPoint(x: holeRect.midX, y: holeRect.minY - OnboardingMetrics.arrowGap)
        } else {
            // 降级布局：主屏顶部居中放卡片，箭头指向屏幕右上角（菜单栏附加图标区）方向，不画孔
            cardRect = CGRect(x: limit.midX - cardSize.width / 2,
                              y: screen.visibleFrame.maxY - OnboardingMetrics.fallbackTopGap - cardSize.height,
                              width: cardSize.width, height: cardSize.height)
            cardRect = Self.clamp(cardRect, in: limit)
            tip = CGPoint(x: screen.frame.maxX - OnboardingMetrics.fallbackTipInset,
                          y: screen.frame.maxY - 12)
        }

        // 曲线起点落在卡片上缘：有孔时与孔水平对齐（并内缩避开卡片圆角），降级布局时从右侧出发
        let startX: CGFloat
        if anchor != nil {
            startX = min(max(tip.x, cardRect.minX + OnboardingMetrics.arrowEdgeInset),
                         cardRect.maxX - OnboardingMetrics.arrowEdgeInset)
        } else {
            startX = cardRect.maxX - OnboardingMetrics.arrowEdgeInset
        }
        let start = CGPoint(x: startX, y: cardRect.maxY + OnboardingMetrics.arrowGap)

        card.setFrameOrigin(CGPoint(x: cardRect.minX - shift.x, y: cardRect.minY - shift.y))
        mask.addSubview(card)
        mask.cardFrame = card.frame
        mask.holeRect = hole.map { CGRect(x: $0.minX - shift.x, y: $0.minY - shift.y,
                                          width: $0.width, height: $0.height) }
        mask.arrowStart = CGPoint(x: start.x - shift.x, y: start.y - shift.y)
        mask.arrowTip = CGPoint(x: tip.x - shift.x, y: tip.y - shift.y)
    }

    // MARK: - 呼吸动画

    /// 只有画了高亮孔才需要呼吸动画。用 `.common` 模式挂到主 runloop，菜单跟踪期间也不会停。
    private func startBreathing() {
        guard maskViews.contains(where: { $0.holeRect != nil }) else { return }
        breathStart = CACurrentMediaTime()
        let timer = Timer(timeInterval: OnboardingMetrics.breathTick, repeats: true) { [weak self] _ in
            self?.tickBreathing()
        }
        RunLoop.main.add(timer, forMode: .common)
        breathTimer = timer
    }

    private func tickBreathing() {
        let elapsed = CACurrentMediaTime() - breathStart
        let phase = elapsed.truncatingRemainder(dividingBy: OnboardingMetrics.breathPeriod)
            / OnboardingMetrics.breathPeriod
        // 一个周期内亮一次：0 → 1 → 0
        let wave = CGFloat((1 - cos(2 * Double.pi * phase)) / 2)
        let alpha = OnboardingMetrics.breathMinAlpha
            + (OnboardingMetrics.breathMaxAlpha - OnboardingMetrics.breathMinAlpha) * wave
        for mask in maskViews { mask.updateStrokeAlpha(alpha) }
    }

    // MARK: - 屏幕变化

    /// 分辨率 / 屏幕排列一变，挖孔与卡片的几何全部失效，直接收起引导
    /// （用户可以从菜单栏的「显示上手引导」重看）。
    private func observeScreenChanges() {
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Log.debug("屏幕参数变化，收起引导浮层")
            self?.close()
        }
    }

    // MARK: - 关闭

    /// 点高亮孔 / 主按钮：先关引导再弹菜单。
    /// 顺序很关键——`CGShieldingWindowLevel()` 的遮罩还在屏上时，状态栏菜单会被压住，
    /// 所以等遮罩 `orderOut` 后再异步触发回调。
    private func openMenuThenClose() {
        let open = onOpenMenu
        onOpenMenu = nil
        close()
        guard let open else { return }
        DispatchQueue.main.async { open() }
    }

    /// 唯一的关闭出口：停动画、收窗口、摘观察者，最后回调一次 `onDismiss`。
    private func close() {
        guard !isFinished else { return }
        isFinished = true

        breathTimer?.invalidate()
        breathTimer = nil

        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
        }
        screenObserver = nil

        for window in windows { window.orderOut(nil) }
        windows.removeAll()
        maskViews.removeAll()

        if OnboardingOverlay.current === self { OnboardingOverlay.current = nil }

        let dismissed = onDismiss
        onDismiss = nil
        onOpenMenu = nil
        Log.info("引导浮层已关闭")
        dismissed?()
    }

    // MARK: - 几何工具

    /// 锚点合法性校验：尺寸太小或不落在任何屏幕上都当作拿不到位置，走降级布局。
    private static func sanitize(_ anchor: CGRect?) -> CGRect? {
        guard let anchor, anchor.width > 1, anchor.height > 1,
              anchor.origin.x.isFinite, anchor.origin.y.isFinite else { return nil }
        guard NSScreen.screens.contains(where: { $0.frame.intersects(anchor) }) else {
            Log.warn("引导浮层：菜单栏图标位置 \(anchor) 不在任何屏幕内，改用降级布局")
            return nil
        }
        return anchor
    }

    /// 锚点所在屏幕：优先取包含中心点的那块，取不到再退化为相交面积最大的那块。
    private static func screen(containing rect: CGRect) -> NSScreen? {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        if let hit = NSScreen.screens.first(where: { $0.frame.contains(center) }) { return hit }
        return NSScreen.screens.max { overlap($0.frame, rect) < overlap($1.frame, rect) }
    }

    private static func overlap(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let i = a.intersection(b)
        return i.isNull ? 0 : i.width * i.height
    }

    /// 把矩形收进 `limit`；`limit` 比矩形还小时退化为居中（小屏 / 缩放异常时不至于跑到屏幕外）。
    private static func clamp(_ rect: CGRect, in limit: CGRect) -> CGRect {
        var r = rect
        if limit.width >= r.width {
            r.origin.x = min(max(r.minX, limit.minX), limit.maxX - r.width)
        } else {
            r.origin.x = limit.midX - r.width / 2
        }
        if limit.height >= r.height {
            r.origin.y = min(max(r.minY, limit.minY), limit.maxY - r.height)
        } else {
            r.origin.y = limit.midY - r.height / 2
        }
        return r
    }
}

// MARK: - 遮罩窗口

/// 单块屏幕上的引导遮罩窗口。层级、collectionBehavior、sharingType 与区域框选保持一致。
private final class OnboardingOverlayWindow: NSWindow {
    init(screen: NSScreen, content: NSView) {
        // 只能调用指定初始化器（带 screen: 的是便利初始化器），因此先用全局坐标建窗再定位
        super.init(contentRect: screen.frame, styleMask: [.borderless],
                   backing: .buffered, defer: false)
        setFrame(screen.frame, display: false)
        level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        ignoresMouseEvents = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        sharingType = .none
        animationBehavior = .none
        isReleasedWhenClosed = false
        content.frame = CGRect(origin: .zero, size: screen.frame.size)
        contentView = content
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

// MARK: - 遮罩内容

/// 遮罩内容：38% 黑底 + 挖空的高亮孔 + 呼吸描边 + 指向高亮孔的曲线箭头。
/// 说明卡片是本视图的子视图，因此总是画在箭头之上。
private final class OnboardingMaskView: NSView {

    /// 用户点了高亮孔（只有图标所在那块屏会接上）
    var onOpenMenu: (() -> Void)?
    /// 点遮罩空白 / 右键 / `⎋`
    var onDismiss: (() -> Void)?

    /// 高亮孔（视图坐标）。nil = 本屏只画纯遮罩
    var holeRect: CGRect? {
        didSet { needsDisplay = true }
    }
    /// 说明卡片 frame（视图坐标），用于把落在卡片上的点击排除掉
    var cardFrame: CGRect?
    /// 曲线起点（卡片上缘）与尖端（指向高亮孔）
    var arrowStart: CGPoint?
    var arrowTip: CGPoint?

    /// 描边当前透明度，由呼吸动画驱动
    private var strokeAlpha: CGFloat = OnboardingMetrics.breathMaxAlpha

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// 只重绘高亮孔那一小块，呼吸动画不会带着整屏遮罩重画。
    /// `draw(_:)` 每次都会把箭头整条重画，所以局部刷新不会擦掉压在孔附近的箭头。
    func updateStrokeAlpha(_ alpha: CGFloat) {
        guard let hole = holeRect, abs(alpha - strokeAlpha) > 0.005 else { return }
        strokeAlpha = alpha
        let slop = OnboardingMetrics.holeStrokeWidth + 2
        setNeedsDisplay(hole.insetBy(dx: -slop, dy: -slop))
    }

    override func resetCursorRects() {
        guard let hole = holeRect else { return }
        addCursorRect(hole, cursor: .pointingHand)
    }

    // MARK: - 绘制

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(OnboardingMetrics.maskAlpha).setFill()
        bounds.fill()

        if let hole = holeRect { drawHole(hole) }
        drawArrow()
    }

    /// 挖空高亮孔 + 孔外描边。与区域框选同一手法：`NSColor.clear` 配 `.copy` 直接把遮罩打穿。
    private func drawHole(_ hole: CGRect) {
        let radius = min(OnboardingMetrics.holeCornerRadius, min(hole.width, hole.height) / 2)
        let path = NSBezierPath(roundedRect: hole, xRadius: radius, yRadius: radius)

        if let ctx = NSGraphicsContext.current {
            ctx.saveGraphicsState()
            ctx.compositingOperation = .copy
            NSColor.clear.setFill()
            path.fill()
            ctx.restoreGraphicsState()
        }

        // 挖穿后这块区域 alpha 归零，而非透明窗口在全透明处会把点击漏给底下的菜单栏，
        // 于是补一层 2% 白把 alpha 抬回非零：视觉上看不出来，但「点孔」仍由本视图接住。
        NSColor.white.withAlphaComponent(0.02).setFill()
        path.fill()

        let inset = OnboardingMetrics.holeStrokeWidth / 2
        let ring = NSBezierPath(roundedRect: hole.insetBy(dx: -inset, dy: -inset),
                                xRadius: radius + inset, yRadius: radius + inset)
        ring.lineWidth = OnboardingMetrics.holeStrokeWidth
        NSColor.controlAccentColor.withAlphaComponent(strokeAlpha).setStroke()
        ring.stroke()
    }

    /// 从卡片上缘到高亮孔下缘的三次贝塞尔曲线，末端补一个指向孔的实心三角。
    private func drawArrow() {
        guard let start = arrowStart, let tip = arrowTip else { return }
        let dx = tip.x - start.x
        let dy = tip.y - start.y
        guard abs(dx) + abs(dy) > 16 else { return }

        // 横向张力：孔与卡片几乎垂直对齐时也保证是一条看得出弧度的曲线
        let lateral = max(26, abs(dx) * 0.3) * (dx >= 0 ? 1 : -1)
        let cp1 = CGPoint(x: start.x + lateral, y: start.y + dy * 0.45)
        let cp2 = CGPoint(x: tip.x - lateral * 0.35, y: tip.y - dy * 0.5)

        // 曲线停在三角底边，避免线头从箭头尖里透出来
        let angle = atan2(tip.y - cp2.y, tip.x - cp2.x)
        let base = CGPoint(x: tip.x - cos(angle) * OnboardingMetrics.arrowHeadLength,
                           y: tip.y - sin(angle) * OnboardingMetrics.arrowHeadLength)

        let curve = NSBezierPath()
        curve.move(to: start)
        curve.curve(to: base, controlPoint1: cp1, controlPoint2: cp2)
        curve.lineWidth = OnboardingMetrics.arrowLineWidth
        curve.lineCapStyle = .round
        NSColor.controlAccentColor.setStroke()
        curve.stroke()

        let perp = angle + CGFloat.pi / 2
        let half = OnboardingMetrics.arrowHeadHalfWidth
        let head = NSBezierPath()
        head.move(to: tip)
        head.line(to: CGPoint(x: base.x + cos(perp) * half, y: base.y + sin(perp) * half))
        head.line(to: CGPoint(x: base.x - cos(perp) * half, y: base.y - sin(perp) * half))
        head.close()
        NSColor.controlAccentColor.setFill()
        head.fill()
    }

    // MARK: - 事件

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)

        // 卡片自己会吞掉落在它身上的点击（见 OnboardingCardView），这里再兜一层保险
        if let cardFrame, cardFrame.contains(point) { return }

        let slop = OnboardingMetrics.holeHitSlop
        if let hole = holeRect, hole.insetBy(dx: -slop, dy: -slop).contains(point),
           let onOpenMenu {
            onOpenMenu()
            return
        }
        onDismiss?()
    }

    override func rightMouseDown(with event: NSEvent) { onDismiss?() }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onDismiss?() } else { super.keyDown(with: event) }
    }
}

// MARK: - 说明卡片

/// 说明卡片：HUD 材质圆角卡 + 标题 / 正文 / 快捷键行 / 两个按钮。
/// 纯手工摆位（无 xib、无 Auto Layout）：测量与绘制用同一套字体，高度在 init 里一次算好。
private final class OnboardingCardView: NSView {

    private enum Pad {
        static let horizontal: CGFloat = 18
        static let top: CGFloat = 16
        static let bottom: CGFloat = 14
        static let titleToBody: CGFloat = 8
        static let bodyToShortcut: CGFloat = 10
        static let shortcutToButtons: CGFloat = 14
        static let buttonSpacing: CGFloat = 10
        static let minButtonWidth: CGFloat = 78
        static let minButtonHeight: CGFloat = 24
    }

    /// 「打开菜单」
    var onPrimary: (() -> Void)?
    /// 「知道了」
    var onSecondary: (() -> Void)?

    private let backdrop = NSVisualEffectView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let bodyLabel = NSTextField(labelWithString: "")
    private let shortcutLabel = NSTextField(labelWithString: "")
    private let primaryButton = NSButton()
    private let secondaryButton = NSButton()

    /// 三段文字在固定宽度下量出的高度，`layout()` 与卡片总高共用同一份测量结果
    private var titleHeight: CGFloat = 0
    private var bodyHeight: CGFloat = 0
    private var shortcutHeight: CGFloat = 0
    private var buttonHeight: CGFloat = Pad.minButtonHeight
    /// 供 VoiceOver 朗读的整卡摘要（标题 + 正文 + 快捷键行）
    private var accessibilitySummary = ""

    init(width: CGFloat) {
        super.init(frame: CGRect(x: 0, y: 0, width: width, height: width))

        wantsLayer = true
        // HUD 材质本就是暗色，强制暗色外观让 labelColor / secondaryLabelColor 解析成浅色
        appearance = NSAppearance(named: .darkAqua)
        // 兜底底色：万一 HUD 材质在 shielding 层级上没生效，卡片也不会变成透明的一块
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.82).cgColor
        layer?.cornerRadius = OnboardingMetrics.cardCornerRadius
        layer?.masksToBounds = true

        setupBackdrop()
        let contentWidth = width - Pad.horizontal * 2
        setupLabels(contentWidth: contentWidth)
        setupButtons()

        // 高度 = 上下内边距 + 三段文字 + 间距 + 按钮行
        let height = Pad.top + titleHeight + Pad.titleToBody + bodyHeight
            + Pad.bodyToShortcut + shortcutHeight + Pad.shortcutToButtons
            + buttonHeight + Pad.bottom
        setFrameSize(CGSize(width: width, height: ceil(height)))

        setAccessibilityRole(.group)
        setAccessibilityLabel(accessibilitySummary)
        positionSubviews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("OnboardingCardView 为纯代码视图，不支持 xib / storyboard 加载")
    }

    // MARK: - 子视图

    private func setupBackdrop() {
        backdrop.material = .hudWindow
        backdrop.blendingMode = .withinWindow
        backdrop.state = .active
        backdrop.wantsLayer = true
        backdrop.layer?.cornerRadius = OnboardingMetrics.cardCornerRadius
        backdrop.layer?.masksToBounds = true
        backdrop.layer?.borderWidth = 1
        backdrop.layer?.borderColor = NSColor.white.withAlphaComponent(0.14).cgColor
        backdrop.autoresizingMask = [.width, .height]
        addSubview(backdrop)
    }

    private func setupLabels(contentWidth: CGFloat) {
        let titleFont = NSFont.systemFont(ofSize: 15, weight: .semibold)
        let bodyFont = NSFont.systemFont(ofSize: 12)
        let shortcutFont = NSFont.systemFont(ofSize: 11)

        let title = L.t("MyWindowPip 已在后台运行", "MyWindowPip is running in the background")
        let body = L.t("它常驻菜单栏，没有主窗口。点这个图标 → 选择窗口，就能把任意窗口变成画中画。",
                       "It lives in the menu bar and has no main window. "
                           + "Click the icon → Choose Window to mirror any window.")
        // 快捷键取当前实际配置（默认就是 ⌃⌥P / ⌃⌥⇧P），用户改过热键后引导里显示的也是对的
        let prefs = Preferences.shared
        let pipKeys = prefs.pipHotkey.displayString
        let regionKeys = prefs.regionHotkey.displayString
        let shortcut = L.t("\(pipKeys) 画中画前台窗口　\(regionKeys) 区域捕获",
                           "\(pipKeys) PiP the frontmost window　\(regionKeys) Capture a region")

        configure(titleLabel, text: title, font: titleFont, color: .labelColor, width: contentWidth)
        configure(bodyLabel, text: body, font: bodyFont, color: .labelColor, width: contentWidth)
        configure(shortcutLabel, text: shortcut, font: shortcutFont,
                  color: .secondaryLabelColor, width: contentWidth)

        titleHeight = Self.height(of: title, font: titleFont, width: contentWidth)
        bodyHeight = Self.height(of: body, font: bodyFont, width: contentWidth)
        shortcutHeight = Self.height(of: shortcut, font: shortcutFont, width: contentWidth)

        accessibilitySummary = [title, body, shortcut].joined(separator: L.t("，", ". "))
    }

    private func configure(_ label: NSTextField, text: String, font: NSFont,
                           color: NSColor, width: CGFloat) {
        label.stringValue = text
        label.font = font
        label.textColor = color
        label.alignment = .left
        label.usesSingleLineMode = false
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 0
        label.preferredMaxLayoutWidth = width
        label.cell?.wraps = true
        label.cell?.isScrollable = false
        addSubview(label)
    }

    private func setupButtons() {
        let primaryTitle = L.t("打开菜单", "Open Menu")
        let secondaryTitle = L.t("知道了", "Got it")

        primaryButton.bezelStyle = .rounded
        primaryButton.title = primaryTitle
        // 回车即主按钮：遮罩窗口是 key window，keyEquivalent 才有机会被响应
        primaryButton.keyEquivalent = "\r"
        primaryButton.target = self
        primaryButton.action = #selector(handlePrimary)
        primaryButton.setAccessibilityLabel(primaryTitle)
        addSubview(primaryButton)

        secondaryButton.bezelStyle = .rounded
        secondaryButton.title = secondaryTitle
        secondaryButton.target = self
        secondaryButton.action = #selector(handleSecondary)
        secondaryButton.setAccessibilityLabel(secondaryTitle)
        addSubview(secondaryButton)

        buttonHeight = max(Pad.minButtonHeight, ceil(primaryButton.fittingSize.height))
    }

    // MARK: - 布局

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        positionSubviews()
    }

    override func layout() {
        super.layout()
        positionSubviews()
    }

    /// 自上而下摆位：标题 → 正文 → 快捷键行 → 按钮（靠右，主按钮在最右）。
    private func positionSubviews() {
        backdrop.frame = bounds
        let contentWidth = max(0, bounds.width - Pad.horizontal * 2)

        var y = bounds.maxY - Pad.top - titleHeight
        titleLabel.frame = CGRect(x: Pad.horizontal, y: y, width: contentWidth, height: titleHeight)

        y -= Pad.titleToBody + bodyHeight
        bodyLabel.frame = CGRect(x: Pad.horizontal, y: y, width: contentWidth, height: bodyHeight)

        y -= Pad.bodyToShortcut + shortcutHeight
        shortcutLabel.frame = CGRect(x: Pad.horizontal, y: y, width: contentWidth, height: shortcutHeight)

        let primaryWidth = max(Pad.minButtonWidth, ceil(primaryButton.fittingSize.width))
        let secondaryWidth = max(Pad.minButtonWidth, ceil(secondaryButton.fittingSize.width))
        let buttonY = bounds.minY + Pad.bottom
        primaryButton.frame = CGRect(x: bounds.maxX - Pad.horizontal - primaryWidth, y: buttonY,
                                     width: primaryWidth, height: buttonHeight)
        secondaryButton.frame = CGRect(x: primaryButton.frame.minX - Pad.buttonSpacing - secondaryWidth,
                                       y: buttonY, width: secondaryWidth, height: buttonHeight)
    }

    /// 测量换行后的文字高度。`+2` 是给 `NSTextField` 的 cell 内边距留的容错，
    /// 量少了最后一行会被切掉（提示条截断那个坑就是这么来的）。
    private static func height(of text: String, font: NSFont, width: CGFloat) -> CGFloat {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byWordWrapping
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .paragraphStyle: style]
        let rect = (text as NSString).boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attrs
        )
        return ceil(rect.height) + 2
    }

    // MARK: - 事件

    @objc private func handlePrimary() { onPrimary?() }
    @objc private func handleSecondary() { onSecondary?() }

    /// 吞掉落在卡片上的点击（含背景材质那一层），否则事件会顺着响应链传到遮罩视图上，
    /// 变成"点卡片也把引导关掉"。
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {}
    override func rightMouseDown(with event: NSEvent) {}
}
