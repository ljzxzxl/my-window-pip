import AppKit
import ScreenCaptureKit

// MARK: - 菜单用分组

/// 按 App 聚合后的窗口分组，供菜单栏渲染（App 图标 + 该 App 的窗口列表）。
struct WindowGroup {
    let appName: String
    let bundleID: String?
    /// App 图标，来自 `NSRunningApplication(processIdentifier:)?.icon`
    let icon: NSImage?
    let windows: [SCWindow]
}

// MARK: - 可共享内容缓存

/// `SCShareableContent` 的查询封装与缓存。
///
/// 设计要点：
/// - 单次查询要数十毫秒，菜单栏点开时必须立即有数据，因此做 1 秒 TTL 缓存；
///   过期时先返回旧值再触发后台刷新（getter 不阻塞）。
/// - 枚举覆盖全部 Space；缓存分三份：`candidates`（可作为 PiP 源，已过滤）、`all`
///   （不含自身 App 的全部窗口，供按 ID 精确查找）、`own`（自身 App 的窗口，区域捕获时
///   要排除，防止镜中镜）。前台窗口入口再按实时 onscreen + WindowServer 层级收窄。
/// - 对外语义是「主线程访问」；但 `cachedWindow(id:)` 属于高频路径，可能在捕获队列上被调用，
///   因此所有缓存读写都用一把锁保护，跨线程读取安全（读到的是某一时刻的快照）。
///
/// `@unchecked Sendable` 的依据：缓存字段全部由 `lock` 保护；`isFetching` / `pendingCompletions`
/// 只在主线程读写；`SCWindow` / `SCDisplay` 是 SCK 给出的只读快照对象，跨线程只读不改。
final class ShareableContentStore: @unchecked Sendable {

    static let shared = ShareableContentStore()

    /// 缓存有效期（秒）
    static let ttl: TimeInterval = 1.0
    /// 窗口最小边长（点）：更小的多为分隔条/阴影层/输入法候选窗，不作为 PiP 源
    static let minWindowSide: CGFloat = 80
    /// 无标题窗口的最小面积（点²）：无标题且很小的基本都是浮层
    static let minUntitledArea: CGFloat = 200 * 200

    private init() {}

    // MARK: 内部状态

    /// 保护下面所有缓存字段（可能被捕获队列读取）
    private let lock = NSLock()
    /// 已过滤的候选窗口（排除自身 App、过小窗口）
    private var candidatesCache: [SCWindow] = []
    /// 不含自身 App 的全部窗口，供按 CGWindowID 查找（哪怕它很小）
    private var allCache: [SCWindow] = []
    /// 自身 App 的窗口（浮窗自己），区域捕获排除用
    private var ownCache: [SCWindow] = []
    private var displaysCache: [SCDisplay] = []
    /// 窗口在其所属 App 内的序号（1 起），用于无标题窗口的兜底命名
    private var ordinalCache: [CGWindowID: Int] = [:]
    /// 上次成功查询的时间（`systemUptime`，单调）；初值取负数保证首次即为过期
    private var lastSuccessUptime: TimeInterval = -.greatestFiniteMagnitude

    /// 以下两个字段只在主线程读写
    private var isFetching = false
    private var pendingCompletions: [(Result<[SCWindow], Error>) -> Void] = []

    private static let ownProcessID: pid_t = ProcessInfo.processInfo.processIdentifier
    private static let ownBundleID: String? = Bundle.main.bundleIdentifier

    // MARK: - 只读缓存

    /// 最近一次成功查询并过滤后的窗口列表。
    /// 缓存过期时仍返回旧值，同时触发一次后台刷新（合并并发请求）。
    var cachedWindows: [SCWindow] {
        let snapshot = withLock { (candidatesCache, isExpiredLocked) }
        if snapshot.1 { refresh() }
        return snapshot.0
    }

    /// 最近一次查询到的显示器列表（区域捕获构造 display 过滤器时需要）。
    var cachedDisplays: [SCDisplay] {
        let snapshot = withLock { (displaysCache, isExpiredLocked) }
        if snapshot.1 { refresh() }
        return snapshot.0
    }

    /// 自身 App 当前的窗口（PiP 浮窗自己）。
    /// 区域捕获走显示器流时必须把它们排除，否则浮窗会把自己拍进去形成镜中镜。
    var cachedOwnWindows: [SCWindow] {
        let snapshot = withLock { (ownCache, isExpiredLocked) }
        if snapshot.1 { refresh() }
        return snapshot.0
    }

    /// 缓存是否已过期（外部可用于决定是否要等一次刷新）
    var isCacheExpired: Bool { withLock { isExpiredLocked } }

    // MARK: - 刷新

    /// 异步刷新缓存。并发调用会被合并为一次查询，所有 completion 都会被回调（主线程）。
    func refresh(completion: ((Result<[SCWindow], Error>) -> Void)? = nil) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.refresh(completion: completion) }
            return
        }
        if let completion { pendingCompletions.append(completion) }
        guard !isFetching else { return }   // 已有查询在飞，等它的结果
        isFetching = true

        // SCShareableContent 的查询是 async throws，包在 Task 里执行，结果切回主线程处理。
        Task {
            do {
                // 菜单、按 ID 存活检查和断线恢复都必须能看到其它 Space / 最小化窗口。
                // 是否位于当前前台只属于 `frontmostWindow` 的选择条件，不能在枚举源头过滤。
                let content = try await SCShareableContent.excludingDesktopWindows(
                    true, onScreenWindowsOnly: false
                )
                let snapshot = ContentSnapshot(content)
                DispatchQueue.main.async { self.finishRefresh(.success(snapshot)) }
            } catch {
                DispatchQueue.main.async { self.finishRefresh(.failure(error)) }
            }
        }
    }

    /// 查询结果的原始快照。`SCWindow` / `SCDisplay` 均为只读对象，跨线程传递只读不改。
    private struct ContentSnapshot: @unchecked Sendable {
        let windows: [SCWindow]
        let displays: [SCDisplay]
        init(_ content: SCShareableContent) {
            windows = content.windows
            displays = content.displays
        }
    }

    private func finishRefresh(_ result: Result<ContentSnapshot, Error>) {
        isFetching = false
        let completions = pendingCompletions
        pendingCompletions.removeAll()

        switch result {
        case let .success(snapshot):
            store(snapshot)
            let windows = withLock { candidatesCache }
            completions.forEach { $0(.success(windows)) }
        case let .failure(error):
            Log.warn("枚举可共享内容失败：\(error.localizedDescription)")
            completions.forEach { $0(.failure(error)) }
        }
    }

    /// 分类 + 过滤 + 写入缓存。
    private func store(_ snapshot: ContentSnapshot) {
        var all: [SCWindow] = []
        var own: [SCWindow] = []
        var candidates: [SCWindow] = []
        var ordinals: [CGWindowID: Int] = [:]
        var counterByPID: [pid_t: Int] = [:]

        for window in snapshot.windows {
            // 防止镜中镜：自身 App 的窗口一律不作为源
            if Self.isOwnWindow(window) {
                own.append(window)
                continue
            }
            all.append(window)
            let pid = window.owningApplication?.processID ?? -1
            let n = (counterByPID[pid] ?? 0) + 1
            counterByPID[pid] = n
            ordinals[window.windowID] = n
            if Self.isCandidate(window) { candidates.append(window) }
        }

        lock.lock()
        allCache = all
        ownCache = own
        candidatesCache = candidates
        displaysCache = snapshot.displays
        ordinalCache = ordinals
        lastSuccessUptime = ProcessInfo.processInfo.systemUptime
        lock.unlock()
    }

    // MARK: - 查询接口

    /// 当前真正位于前台的主窗口：前台 App pid + WindowServer 前后顺序 + onscreen 普通层窗口。
    func frontmostWindow(completion: @escaping (SCWindow?) -> Void) {
        withFreshCache { [weak self] in
            completion(self?.frontmostWindowFromCache())
        }
    }

    /// 按 App 分组（每组按标题排序），供菜单栏渲染。
    func grouped(completion: @escaping ([WindowGroup]) -> Void) {
        withFreshCache { [weak self] in
            completion(self?.groupsFromCache() ?? [])
        }
    }

    /// 用 CGWindowID 找当前仍然存在的窗口（会先确保缓存新鲜）。
    func window(id: CGWindowID, completion: @escaping (SCWindow?) -> Void) {
        withFreshCache { [weak self] in
            completion(self?.lookup(id: id))
        }
    }

    /// 同步版本：只查缓存、不发起查询，供高频路径（帧回调、悬停轮询）使用。
    func cachedWindow(id: CGWindowID) -> SCWindow? { lookup(id: id) }

    /// 按 bundleID + 标题模糊重匹配，供源 App 退出后重开时热重连。
    /// 优先级：标题完全相等 > 前缀互为包含 > 子串包含 > 唯一候选。
    func rematch(bundleID: String?, appName: String, title: String,
                 completion: @escaping (SCWindow?) -> Void) {
        withFreshCache { [weak self] in
            guard let self else { completion(nil); return }
            let candidates = self.cachedWindows.filter { window in
                guard let app = window.owningApplication else { return false }
                if let bundleID, !bundleID.isEmpty { return app.bundleIdentifier == bundleID }
                return app.applicationName.caseInsensitiveCompare(appName) == .orderedSame
            }
            completion(Self.bestMatch(in: candidates, title: title))
        }
    }

    /// 按 displayID 找显示器（区域捕获重建流时用）。
    func display(id: CGDirectDisplayID, completion: @escaping (SCDisplay?) -> Void) {
        withFreshCache { [weak self] in
            completion(self?.cachedDisplays.first { $0.displayID == id })
        }
    }

    // MARK: - 展示与转换

    /// 菜单/标题用的显示名：`App 名 · 窗口标题`，标题为空时兜底 `App 名 – 窗口 #n`。
    func displayTitle(for window: SCWindow) -> String {
        let app = Self.appName(of: window)
        let title = Self.trimmedTitle(of: window)
        if title.isEmpty { return "\(app) – \(fallbackTitle(for: window))" }
        return "\(app) · \(title)"
    }

    /// `SCWindow` → `CaptureSource.window(...)`。标题为空时写入兜底名，便于后续重匹配与展示。
    func captureSource(for window: SCWindow) -> CaptureSource {
        .window(
            id: window.windowID,
            bundleID: window.owningApplication?.bundleIdentifier,
            appName: Self.appName(of: window),
            title: Self.trimmedTitle(of: window)
        )
    }

    /// 窗口的捕获像素尺寸 = 逻辑尺寸 × 所在屏幕 backingScaleFactor（找不到屏幕按 2.0 兜底）。
    func pixelSize(of window: SCWindow) -> CGSize {
        let frame = window.frame
        guard frame.width.isFinite, frame.height.isFinite, frame.width > 0, frame.height > 0 else {
            return .zero
        }
        let scale = Self.backingScale(forTopLeftRect: frame)
        return CGSize(width: frame.width * scale, height: frame.height * scale)
    }

    /// 窗口所在屏幕的 backingScaleFactor（窗口中心命中判定；找不到时 2.0）。
    func backingScale(of window: SCWindow) -> CGFloat {
        Self.backingScale(forTopLeftRect: window.frame)
    }

    // MARK: - 缓存内计算

    private func frontmostWindowFromCache() -> SCWindow? {
        let windows = withLock { candidatesCache }
        // WindowServer ID 按约定唯一；覆盖式构造仍可避免异常重复数据导致进程崩溃。
        var byID: [CGWindowID: SCWindow] = [:]
        for window in windows { byID[window.windowID] = window }

        // 全 Space 枚举后不能再依赖 SCK 数组顺序。CGWindowList 给出当前 onscreen 窗口的
        // 实时前后顺序，再按 windowID 映射回 SCWindow，保证快捷键只选当前可见窗口。
        let orderedIDs = Self.orderedOnScreenWindowIDs()
        let orderedOnScreen = (orderedIDs ?? []).compactMap { byID[$0] }
            .filter(Self.hasMainWindowGeometry)

        let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        if let pid = frontmostPID, pid != Self.ownProcessID {
            let matched = orderedOnScreen.filter { $0.owningApplication?.processID == pid }
            if !matched.isEmpty {
                let screenSizes = NSScreen.screens.map { $0.frame.size }
                // 全屏/最大化应用可能同时暴露多个 layer-0 surface，例如 Chrome 会有横跨全屏
                // 但只有百来点高的辅助窗口。此时优先选覆盖屏幕主体且面积最大的窗口，确保
                // 前台 PiP 捕获的是完整主窗口；普通多窗口场景仍保留 WindowServer z-order。
                if let screenFilling = matched
                    .filter({ Geo.isScreenFillingWindow(size: $0.frame.size, screenSizes: screenSizes) })
                    .max(by: { Self.area($0) < Self.area($1) }) {
                    return screenFilling
                }
                return matched[0]
            }
            if orderedIDs == nil {
                let fallbackMatched = windows.filter {
                    $0.owningApplication?.processID == pid && Self.isMainLike($0)
                }
                let screenSizes = NSScreen.screens.map { $0.frame.size }
                if let screenFilling = fallbackMatched
                    .filter({ Geo.isScreenFillingWindow(size: $0.frame.size, screenSizes: screenSizes) })
                    .max(by: { Self.area($0) < Self.area($1) }) {
                    return screenFilling
                }
                return fallbackMatched.first
            }
            return nil
        }

        // 自身在前台（例如状态栏菜单触发）时，退化为最前面的非自身可捕获窗口。
        if let frontmost = orderedOnScreen.first { return frontmost }
        guard orderedIDs == nil else { return nil }
        return windows.first(where: Self.isMainLike)
    }

    private func groupsFromCache() -> [WindowGroup] {
        let windows = withLock { candidatesCache }.filter { $0.windowLayer == 0 }
        // 同一 bundleID 可能有多个进程实例，按 pid 分组更准确
        var order: [pid_t] = []
        var byPID: [pid_t: [SCWindow]] = [:]
        for window in windows {
            let pid = window.owningApplication?.processID ?? -1
            if byPID[pid] == nil { order.append(pid) }
            byPID[pid, default: []].append(window)
        }

        let groups: [WindowGroup] = order.compactMap { pid in
            guard let list = byPID[pid], !list.isEmpty else { return nil }
            let sorted = list.sorted { lhs, rhs in
                let a = displayTitle(for: lhs), b = displayTitle(for: rhs)
                let cmp = a.localizedStandardCompare(b)
                return cmp == .orderedSame ? lhs.windowID < rhs.windowID : cmp == .orderedAscending
            }
            let app = list.first?.owningApplication
            return WindowGroup(
                appName: app?.applicationName ?? L.t("未知应用", "Unknown App"),
                bundleID: app?.bundleIdentifier,
                icon: pid > 0 ? NSRunningApplication(processIdentifier: pid)?.icon : nil,
                windows: sorted
            )
        }
        return groups.sorted { $0.appName.localizedStandardCompare($1.appName) == .orderedAscending }
    }

    private func lookup(id: CGWindowID) -> SCWindow? {
        withLock { allCache.first { $0.windowID == id } }
    }

    private func fallbackTitle(for window: SCWindow) -> String {
        let n = withLock { ordinalCache[window.windowID] } ?? 1
        return "\(L.t("窗口", "Window")) #\(n)"
    }

    // MARK: - 静态判定

    private static func isOwnWindow(_ window: SCWindow) -> Bool {
        guard let app = window.owningApplication else { return false }
        if app.processID == ownProcessID { return true }
        if let ownBundleID, app.bundleIdentifier == ownBundleID { return true }
        return false
    }

    /// 是否适合出现在窗口选择菜单。
    /// 全 Space 枚举会带回后台代理和内部 surface；这里只保留用户可理解的普通窗口。
    private static func isCandidate(_ window: SCWindow) -> Bool {
        guard window.windowLayer == 0,
              let owner = window.owningApplication,
              owner.processID > 0 else { return false }

        let title = trimmedTitle(of: window)
        guard let runningApp = NSRunningApplication(processIdentifier: owner.processID),
              !runningApp.isTerminated,
              !runningApp.isHidden else { return false }
        switch runningApp.activationPolicy {
        case .regular:
            break
        case .accessory:
            guard window.isOnScreen, !title.isEmpty else { return false }
        case .prohibited:
            return false
        @unknown default:
            guard window.isOnScreen, !title.isEmpty else { return false }
        }

        let frame = window.frame
        guard frame.width.isFinite, frame.height.isFinite else { return false }
        guard frame.width >= minWindowSide, frame.height >= minWindowSide else { return false }
        if !window.isOnScreen, title.isEmpty { return false }
        if title.isEmpty, area(window) < minUntitledArea { return false }
        return true
    }

    /// 像「App 主窗口」：普通层级 + 在屏 + 尺寸大于阈值。
    private static func isMainLike(_ window: SCWindow) -> Bool {
        window.isOnScreen && hasMainWindowGeometry(window)
    }

    /// 普通主窗口的稳定属性；是否在屏由调用方根据实时 WindowServer 信息判断。
    private static func hasMainWindowGeometry(_ window: SCWindow) -> Bool {
        window.windowLayer == 0
            && window.frame.width > minWindowSide
            && window.frame.height > minWindowSide
    }

    /// WindowServer 当前 onscreen 窗口的前后顺序（最前面的在前）。
    private static func orderedOnScreenWindowIDs() -> [CGWindowID]? {
        guard let list = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else { return nil }
        return list.compactMap { info in
            (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value
        }
    }

    private static func area(_ window: SCWindow) -> CGFloat {
        max(0, window.frame.width) * max(0, window.frame.height)
    }

    private static func appName(of window: SCWindow) -> String {
        let name = window.owningApplication?.applicationName ?? ""
        return name.isEmpty ? L.t("未知应用", "Unknown App") : name
    }

    private static func trimmedTitle(of window: SCWindow) -> String {
        (window.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 断线重连的模糊匹配。
    private static func bestMatch(in candidates: [SCWindow], title: String) -> SCWindow? {
        guard !candidates.isEmpty else { return nil }
        let target = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let largest: ([SCWindow]) -> SCWindow? = { list in
            list.max { area($0) < area($1) }
        }
        guard !target.isEmpty else {
            return candidates.count == 1 ? candidates[0] : nil
        }
        if let hit = largest(candidates.filter { trimmedTitle(of: $0) == target }) { return hit }
        if let hit = largest(candidates.filter {
            let t = trimmedTitle(of: $0)
            return !t.isEmpty && (t.hasPrefix(target) || target.hasPrefix(t))
        }) { return hit }
        if let hit = largest(candidates.filter {
            let t = trimmedTitle(of: $0)
            return !t.isEmpty && (t.contains(target) || target.contains(t))
        }) { return hit }
        // 标题彻底变了：只有唯一候选时才认，避免连错窗口
        return candidates.count == 1 ? candidates[0] : nil
    }

    /// 左上原点全局矩形（`SCWindow.frame` 的坐标系）→ 所在屏幕的 backingScaleFactor。
    private static func backingScale(forTopLeftRect rect: CGRect) -> CGFloat {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return 2.0 }
        // 转成 AppKit 全局坐标（左下原点）后判断中心点落在哪个屏幕
        let centerTopLeft = CGPoint(x: rect.midX, y: rect.midY)
        let center = CGPoint(x: centerTopLeft.x, y: Geo.primaryScreenMaxY - centerTopLeft.y)
        if let hit = screens.first(where: { $0.frame.contains(center) }) {
            return hit.backingScaleFactor
        }
        // 中心点不在任何屏幕上（窗口部分离屏）：取与窗口相交面积最大的屏幕
        let appKitRect = CGRect(x: rect.minX, y: Geo.primaryScreenMaxY - rect.maxY,
                               width: rect.width, height: rect.height)
        let best = screens.max { lhs, rhs in
            let a = lhs.frame.intersection(appKitRect)
            let b = rhs.frame.intersection(appKitRect)
            return (a.isNull ? 0 : a.width * a.height) < (b.isNull ? 0 : b.width * b.height)
        }
        return best?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
    }

    // MARK: - 工具

    private var isExpiredLocked: Bool {
        ProcessInfo.processInfo.systemUptime - lastSuccessUptime > Self.ttl
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    /// 确保缓存尽量新鲜后在主线程执行 `body`。
    /// 缓存未过期且当前已在主线程时**同步**执行（菜单栏需要同步取数据渲染）；
    /// 刷新失败也会继续执行，用旧缓存尽力而为。
    private func withFreshCache(_ body: @escaping () -> Void) {
        if !isCacheExpired {
            if Thread.isMainThread { body() } else { DispatchQueue.main.async(execute: body) }
            return
        }
        refresh { _ in body() }
    }
}
