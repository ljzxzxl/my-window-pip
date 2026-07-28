import AppKit

/// 进度面板的尺寸、字号与节流常量。文件作用域 private，写法与 `OnboardingMetrics` 保持一致。
private enum UpdateProgressMetrics {
    static let panelWidth: CGFloat = 360
    /// 内容区最小高度；实际高度取「内容自适应高度 + 上下内边距」与它的较大值，保证不裁切
    static let panelMinHeight: CGFloat = 120
    static let padding: CGFloat = 16
    static let rowSpacing: CGFloat = 8

    static let titleFontSize: CGFloat = 13
    static let statusFontSize: CGFloat = 11

    /// 节流窗口：距上次刷新不足这么久的更新直接丢弃（下载回调可能每个数据包来一次）
    static let updateThrottle: TimeInterval = 0.1
    /// `finish` 之后自动关闭的等待时间
    static let autoCloseDelay: TimeInterval = 1.5
}

/// 更新下载进度面板。
///
/// 慢链路上 1.9 MB 的 DMG 可能要下 80 秒以上，旧实现整个过程零反馈，用户只能看到
/// 「点了更新 → 没动静 → 弹失败框」。本面板负责把下载过程「变得可见」：
/// 标题 + 确定式进度条 + `1.2 MB / 1.9 MB · 68%` + 「取消」按钮。
///
/// 几个刻意的设计选择：
/// - `NSPanel` + `.nonactivatingPanel`：不抢当前 App 的焦点（本应用是 `LSUIElement`，没有主窗口）
/// - `level = .floating`：**必须低于 PiP 浮窗的 `.screenSaver`**，否则会盖住画中画
/// - 单例复用：重复 `show` 只把已有面板前置，不重建窗口；`dismiss` 只 `orderOut`，实例留着下次用
/// - 所有对外方法内部都会兜一层主线程派发，调用方可以直接从 URLSession 的 delegate 队列调用
final class UpdateProgressWindow: NSObject, NSWindowDelegate {

    // MARK: - 对外 API

    /// 唯一实例。只在主线程读写。
    private static var shared: UpdateProgressWindow?

    /// 面板是否在屏上。可能被非主线程读取（菜单栏刷新、下载回调），因此用锁保护的镜像值。
    static var isVisible: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return visibleState
    }

    /// 当前百分比（0…100）；总大小未知或面板未展示时为 nil。
    /// 菜单栏用它显示「正在下载更新 N%」，所以同样按锁保护的镜像值提供。
    static var percent: Int? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return percentState
    }

    /// 展示进度面板。重复调用只把已有面板前置，不重建窗口。
    /// - Parameters:
    ///   - version: 正在下载的版本号（用于标题）
    ///   - onCancel: 用户点「取消」或标题栏关闭按钮时回调，调用方在此取消下载任务
    static func show(version: String, onCancel: @escaping () -> Void) {
        onMain {
            if let existing = shared {
                existing.reuse(version: version, onCancel: onCancel)
                existing.present(center: false)
            } else {
                let window = UpdateProgressWindow(version: version, onCancel: onCancel)
                shared = window
                window.present(center: true)
            }
        }
    }

    /// 更新进度。`totalBytes <= 0` 表示总大小未知（服务端没给 Content-Length）。
    /// 高频调用安全：内部按「同一百分比 / 100ms」双重节流。
    static func update(bytesWritten: Int64, totalBytes: Int64) {
        onMain {
            guard let window = shared, isVisible else { return }
            window.apply(bytesWritten: bytesWritten, totalBytes: totalBytes)
        }
    }

    /// 显示一句完成 / 收尾文案，1.5 秒后自动关闭。期间再调 `show` 会打断自动关闭。
    static func finish(message: String) {
        onMain {
            guard let window = shared, isVisible else { return }
            window.applyFinish(message: message)
        }
    }

    /// 收起面板：停掉不确定动画与自动关闭定时器、`orderOut`、`percent` 归 nil。重复调用安全。
    static func dismiss() {
        onMain {
            storePercent(nil)
            storeVisible(false)
            shared?.teardown()
        }
    }

    // MARK: - 线程与共享状态

    private static let stateLock = NSLock()
    private static var visibleState = false
    private static var percentState: Int?

    private static func storeVisible(_ value: Bool) {
        stateLock.lock()
        visibleState = value
        stateLock.unlock()
    }

    private static func storePercent(_ value: Int?) {
        stateLock.lock()
        percentState = value
        stateLock.unlock()
    }

    /// 主线程兜底：已经在主线程就同步执行（这样 `show` 之后立刻读 `isVisible` 也是准的），
    /// 否则异步派发。下载回调来自 URLSession 的 delegate 队列，必须经这里。
    private static func onMain(_ work: @escaping () -> Void) {
        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.async(execute: work)
        }
    }

    // MARK: - 视图与实例状态

    /// 内容区可用宽度：面板不可缩放，直接按常量给子视图定宽，布局完全确定，不会有约束冲突
    private static let contentWidth = UpdateProgressMetrics.panelWidth - UpdateProgressMetrics.padding * 2

    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        // 关掉「Zero KB」这类非数字表述，进度里始终要看到具体数值
        formatter.allowsNonnumericFormatting = false
        return formatter
    }()

    private let panel: NSPanel
    private let titleLabel: NSTextField
    private let progressBar: NSProgressIndicator
    private let statusLabel: NSTextField
    private let cancelButton: NSButton

    private var version: String
    private var onCancel: () -> Void

    /// 取消只回调一次（按钮与标题栏关闭按钮汇总到同一条路径）
    private var didCancel = false
    /// 已进入 `finish` 的收尾态：此时忽略迟到的进度回调，别把完成文案冲掉
    private var isFinishing = false
    /// 不确定进度条的动画是否已启动（避免重复 start / stop）
    private var isIndeterminate = false

    /// 节流用：上次真正刷新 UI 的时刻与当时的百分比
    private var lastRenderAt: CFAbsoluteTime = 0
    private var lastRenderedPercent: Int?

    /// `finish` 之后的自动关闭任务，可被新的 `show` 取消
    private var autoCloseWork: DispatchWorkItem?

    private init(version: String, onCancel: @escaping () -> Void) {
        self.version = version
        self.onCancel = onCancel

        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0,
                                width: UpdateProgressMetrics.panelWidth,
                                height: UpdateProgressMetrics.panelMinHeight),
            styleMask: [.titled, .closable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        titleLabel = Self.makeLabel(Self.titleText(version: version),
                                    size: UpdateProgressMetrics.titleFontSize,
                                    bold: true, secondary: false)

        progressBar = NSProgressIndicator()
        progressBar.style = .bar
        progressBar.controlSize = .small
        progressBar.isIndeterminate = false
        progressBar.minValue = 0
        progressBar.maxValue = 100
        progressBar.doubleValue = 0
        progressBar.usesThreadedAnimation = true

        statusLabel = Self.makeLabel(L.t("正在连接…", "Connecting…"),
                                     size: UpdateProgressMetrics.statusFontSize,
                                     bold: false, secondary: true)

        cancelButton = NSButton(title: L.t("取消", "Cancel"), target: nil, action: nil)
        cancelButton.bezelStyle = .rounded
        cancelButton.controlSize = .small

        super.init()

        cancelButton.target = self
        cancelButton.action = #selector(cancelClicked)

        configurePanel()
        buildContent()
        configureAccessibility()
    }

    // MARK: - 面板与内容构建

    private func configurePanel() {
        panel.title = L.t("软件更新", "Software Update")
        // 低于 PiP 浮窗的 .screenSaver，绝不盖住画中画
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true      // 不抢焦点，点按钮也不需要成为 key window
        panel.hidesOnDeactivate = false          // 切到别的 App 时进度依然可见
        panel.isReleasedWhenClosed = false       // 单例复用，关闭不销毁
        panel.isMovableByWindowBackground = true // 挡住内容时可以随手拖走
        // 跟随当前 Space，并允许浮在全屏应用之上，否则用户切个 Space 就以为面板消失了
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.delegate = self
    }

    private func buildContent() {
        let content = NSView(frame: NSRect(x: 0, y: 0,
                                           width: UpdateProgressMetrics.panelWidth,
                                           height: UpdateProgressMetrics.panelMinHeight))

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = UpdateProgressMetrics.rowSpacing
        stack.translatesAutoresizingMaskIntoConstraints = false

        stack.addArrangedSubview(titleLabel)
        stack.addArrangedSubview(progressBar)
        stack.addArrangedSubview(statusLabel)
        stack.addArrangedSubview(makeFooter())

        // 进度条撑满内容宽度
        progressBar.translatesAutoresizingMaskIntoConstraints = false
        progressBar.widthAnchor.constraint(equalToConstant: Self.contentWidth).isActive = true

        content.addSubview(stack)
        // 只钉左上角：子视图都是定宽的，高度由 stack 自己算，不会与窗口尺寸打架
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor,
                                       constant: UpdateProgressMetrics.padding),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor,
                                           constant: UpdateProgressMetrics.padding),
        ])

        panel.contentView = content

        // 内容实际需要多高就给多高（不小于 120），避免内容被裁或出现约束冲突日志
        let needed = ceil(stack.fittingSize.height) + UpdateProgressMetrics.padding * 2
        panel.setContentSize(NSSize(width: UpdateProgressMetrics.panelWidth,
                                    height: max(UpdateProgressMetrics.panelMinHeight, needed)))
    }

    /// 第四行：右对齐的「取消」按钮。用普通容器而不是 NSStackView，
    /// 这样 `finish` 里把按钮 `isHidden` 之后行高不变，面板不会突然抖一下。
    private func makeFooter() -> NSView {
        let footer = NSView()
        footer.translatesAutoresizingMaskIntoConstraints = false
        cancelButton.translatesAutoresizingMaskIntoConstraints = false
        footer.addSubview(cancelButton)
        NSLayoutConstraint.activate([
            footer.widthAnchor.constraint(equalToConstant: Self.contentWidth),
            cancelButton.trailingAnchor.constraint(equalTo: footer.trailingAnchor),
            cancelButton.topAnchor.constraint(equalTo: footer.topAnchor),
            cancelButton.bottomAnchor.constraint(equalTo: footer.bottomAnchor),
        ])
        return footer
    }

    private func configureAccessibility() {
        progressBar.setAccessibilityLabel(L.t("更新下载进度", "Update download progress"))
        cancelButton.setAccessibilityLabel(L.t("取消下载更新", "Cancel update download"))
    }

    // MARK: - 展示 / 复用 / 收起

    private func present(center: Bool) {
        if center { panel.center() }
        // App 未激活时也要能上屏，且不抢焦点
        panel.orderFrontRegardless()
        Self.storeVisible(true)
        Log.debug("更新进度面板：展示 version=\(version) center=\(center)")
    }

    /// 复用已有面板。
    /// 下载中重复触发「检查更新」时只前置、不清空进度；
    /// 版本变了或上一轮已进入收尾态，才视为新一轮下载把进度归零（这也是 `finish` 期间被打断的路径）。
    private func reuse(version newVersion: String, onCancel: @escaping () -> Void) {
        autoCloseWork?.cancel()
        autoCloseWork = nil

        self.onCancel = onCancel
        didCancel = false
        cancelButton.isHidden = false

        if isFinishing || newVersion != version {
            version = newVersion
            titleLabel.stringValue = Self.titleText(version: newVersion)
            resetProgress()
        }
        isFinishing = false
    }

    private func resetProgress() {
        setDeterminate(percent: 0)
        statusLabel.stringValue = L.t("正在连接…", "Connecting…")
        lastRenderAt = 0
        lastRenderedPercent = nil
        Self.storePercent(nil)
    }

    private func teardown() {
        autoCloseWork?.cancel()
        autoCloseWork = nil
        stopIndeterminateIfNeeded()
        isFinishing = false
        if panel.isVisible {
            panel.orderOut(nil)
            Log.debug("更新进度面板：收起 version=\(version)")
        }
    }

    // MARK: - 进度刷新

    private func apply(bytesWritten: Int64, totalBytes: Int64) {
        guard !isFinishing else { return }

        let written = max(0, bytesWritten)
        let pct: Int? = totalBytes > 0
            ? min(100, max(0, Int((Double(written) / Double(totalBytes) * 100).rounded(.down))))
            : nil

        // 节流一：百分比没变就没有新信息可看（下载回调可能一秒来几百次）
        if let pct, pct == lastRenderedPercent { return }
        // 节流二：百分比变了也至少隔 100ms 才刷一次，避免布局与重绘刷爆
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastRenderAt >= UpdateProgressMetrics.updateThrottle else { return }
        lastRenderAt = now
        lastRenderedPercent = pct

        if let pct {
            setDeterminate(percent: pct)
            // 单位由 ByteCountFormatter 本地化，形如 1.2 MB / 1.9 MB · 68%
            statusLabel.stringValue =
                "\(Self.formatBytes(written)) / \(Self.formatBytes(totalBytes)) · \(pct)%"
            Self.storePercent(pct)
        } else {
            // 总大小未知：进度条退化为不确定动画，只报已下载量
            setIndeterminate()
            statusLabel.stringValue = L.t("已下载 \(Self.formatBytes(written))",
                                          "Downloaded \(Self.formatBytes(written))")
            Self.storePercent(nil)
        }
        progressBar.setAccessibilityValueDescription(statusLabel.stringValue)
    }

    private func applyFinish(message: String) {
        autoCloseWork?.cancel()
        isFinishing = true

        setDeterminate(percent: 100)
        statusLabel.stringValue = message
        cancelButton.isHidden = true
        lastRenderedPercent = 100
        Self.storePercent(100)
        progressBar.setAccessibilityValueDescription(message)
        Log.debug("更新进度面板：收尾提示「\(message)」，\(UpdateProgressMetrics.autoCloseDelay)s 后自动关闭")

        // 1.5 秒后自动关闭；期间被新的 show / dismiss 打断时这个任务会被 cancel
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isFinishing else { return }
            UpdateProgressWindow.dismiss()
        }
        autoCloseWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + UpdateProgressMetrics.autoCloseDelay,
                                      execute: work)
    }

    private func setDeterminate(percent: Int) {
        stopIndeterminateIfNeeded()
        progressBar.doubleValue = Double(percent)
    }

    private func setIndeterminate() {
        guard !isIndeterminate else { return }
        isIndeterminate = true
        progressBar.isIndeterminate = true
        progressBar.startAnimation(nil)
    }

    private func stopIndeterminateIfNeeded() {
        guard isIndeterminate else { return }
        isIndeterminate = false
        progressBar.stopAnimation(nil)
        progressBar.isIndeterminate = false
    }

    // MARK: - 取消

    @objc private func cancelClicked() {
        Log.debug("更新进度面板：用户点击取消")
        triggerCancel()
    }

    /// 收起面板后再回调，避免调用方紧接着弹 alert 时面板还压在上面
    private func triggerCancel() {
        guard !didCancel else { return }
        didCancel = true
        let handler = onCancel
        UpdateProgressWindow.dismiss()
        handler()
    }

    /// 标题栏关闭按钮等同「取消」；已经进入收尾态时只收起，不再回调取消（下载其实已经完成了）
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if isFinishing {
            UpdateProgressWindow.dismiss()
        } else {
            triggerCancel()
        }
        return false    // 关闭动作已由 dismiss 的 orderOut 完成，不让系统再走一次 close
    }

    // MARK: - 小工具

    private static func titleText(version: String) -> String {
        L.t("正在下载 MyWindowPip \(version)", "Downloading MyWindowPip \(version)")
    }

    private static func formatBytes(_ bytes: Int64) -> String {
        byteFormatter.string(fromByteCount: bytes)
    }

    private static func makeLabel(_ text: String, size: CGFloat,
                                  bold: Bool, secondary: Bool) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = bold ? .systemFont(ofSize: size, weight: .semibold) : .systemFont(ofSize: size)
        field.textColor = secondary ? .secondaryLabelColor : .labelColor
        field.lineBreakMode = .byTruncatingTail
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(equalToConstant: contentWidth).isActive = true
        return field
    }
}
