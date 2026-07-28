import AppKit

/// 鼠标悬停状态。
/// - `isOverHotZone`：是否落在「热区」（浮窗顶栏）。自动隐藏开启后，画面区域穿透、
///   但顶栏仍要能悬停出现并操作，所以必须把这两个区域分开上报。
/// - `optionHeld`：自动隐藏（点击穿透）时浮窗收不到任何事件，只能靠轮询出来的修饰键做「临时唤回」。
struct HoverState: Equatable {
    var isHovering: Bool
    var isOverHotZone: Bool
    var optionHeld: Bool

    static let none = HoverState(isHovering: false, isOverHotZone: false, optionHeld: false)
}

/// 鼠标悬停监控。
///
/// 为什么用轮询而不是 `NSTrackingArea` / 全局事件监听：
/// 一旦浮窗开启点击穿透（`ignoresMouseEvents = true`），它就再也收不到 mouseExited，
/// 会永久卡在"已隐藏"状态；而全局鼠标监听在部分系统上需要额外权限。
/// 每 100ms 读一次 `NSEvent.mouseLocation` 是零权限且绝对可靠的做法，开销可忽略。
final class HoverMonitor {
    static let shared = HoverMonitor()

    private struct Entry {
        let frameProvider: () -> CGRect?
        let hotZoneProvider: () -> CGRect?
        let onChange: (HoverState) -> Void
        var lastState: HoverState
    }

    private var entries: [UUID: Entry] = [:]
    private var timer: Timer?
    private(set) var hoveredID: UUID?

    /// 轮询间隔（秒）
    var interval: TimeInterval = 0.1

    private init() {}

    var mouseLocation: CGPoint { NSEvent.mouseLocation }

    // MARK: - 注册

    /// 注册一个需要监控的浮窗。
    /// - Parameters:
    ///   - frameProvider: 浮窗整体 frame；返回 nil 表示当前不参与命中（隐藏/关闭中）
    ///   - hotZoneProvider: 热区（顶栏）frame；返回 nil 表示没有热区
    func register(id: UUID, frameProvider: @escaping () -> CGRect?,
                  hotZoneProvider: @escaping () -> CGRect? = { nil },
                  onChange: @escaping (HoverState) -> Void) {
        entries[id] = Entry(frameProvider: frameProvider, hotZoneProvider: hotZoneProvider,
                            onChange: onChange, lastState: .none)
        startIfNeeded()
    }

    func unregister(id: UUID) {
        entries.removeValue(forKey: id)
        if hoveredID == id { hoveredID = nil }
        stopIfIdle()
    }

    /// 当前鼠标是否悬停在某个浮窗上（增强模式判断悬停按键归属时使用）
    func currentHovered() -> UUID? { hoveredID }

    // MARK: - 轮询

    private func startIfNeeded() {
        guard timer == nil, !entries.isEmpty else { return }
        let t = Timer(timeInterval: interval, target: self, selector: #selector(tick),
                      userInfo: nil, repeats: true)
        t.tolerance = interval / 2   // 允许合并唤醒，省电
        RunLoop.main.add(t, forMode: .common)
        timer = t
        Log.debug("HoverMonitor 启动，间隔 \(interval)s")
    }

    private func stopIfIdle() {
        guard entries.isEmpty else { return }
        timer?.invalidate()
        timer = nil
        Log.debug("HoverMonitor 停止")
    }

    @objc private func tick() {
        let mouse = NSEvent.mouseLocation
        let optionHeld = NSEvent.modifierFlags.contains(.option)

        // 命中最上面的一个：按注册顺序无法判断 z 序，改为取包含鼠标且面积最小的窗口，
        // 多个浮窗重叠时体验上更符合直觉。
        var hit: (id: UUID, area: CGFloat)?
        for (id, entry) in entries {
            guard let frame = entry.frameProvider(), frame.contains(mouse) else { continue }
            let area = frame.width * frame.height
            if hit == nil || area < hit!.area { hit = (id, area) }
        }
        hoveredID = hit?.id

        // 逐个派发：状态没变化就不回调，避免每 100ms 触发一次动画
        for (id, entry) in entries {
            let hovering = id == hoveredID
            let overHotZone = hovering && (entry.hotZoneProvider()?.contains(mouse) ?? false)
            let state = HoverState(isHovering: hovering,
                                   isOverHotZone: overHotZone,
                                   optionHeld: hovering ? optionHeld : false)
            guard state != entry.lastState else { continue }
            entries[id]?.lastState = state
            entry.onChange(state)
        }
    }
}
