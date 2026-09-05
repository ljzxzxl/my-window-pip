import AppKit

/// 鼠标悬停状态。
/// - `isOverHotZone`：是否落在「热区」（浮窗顶栏）。自动隐藏开启后，画面区域穿透、
///   但顶栏仍要能悬停出现并操作，所以必须把这两个区域分开上报。
/// - `optionHeld` / `commandHeld`：自动隐藏（点击穿透）时浮窗收不到任何事件，
///   只能靠轮询出来的修饰键做「临时唤回」。⌥ 用于普通 peek，⌘ 用于恢复 Cmd 框选缩放。
struct HoverState: Equatable {
    var isHovering: Bool
    var isOverHotZone: Bool
    var isOverResizeZone: Bool
    var optionHeld: Bool
    var commandHeld: Bool

    static let none = HoverState(
        isHovering: false,
        isOverHotZone: false,
        isOverResizeZone: false,
        optionHeld: false,
        commandHeld: false
    )
}

enum AutoHideHoverIntent: Equatable {
    case leave
    case resize
    case bar
    case command
    case option
    case fade
}

/// 纯策略：把 HoverMonitor 的零权限轮询结果转换成自动隐藏动作，便于单元测试。
func autoHideHoverIntent(for state: HoverState) -> AutoHideHoverIntent {
    guard state.isHovering else { return .leave }
    // 显式修饰键优先：Cmd 仍用于框选，Option 仍用于普通 peek。
    if state.commandHeld { return .command }
    if state.optionHeld { return .option }
    // 边缘热区优先于顶栏：顶部最外圈要留给系统 resize，顶栏内部才用于按钮/拖动。
    if state.isOverResizeZone { return .resize }
    if state.isOverHotZone { return .bar }
    return .fade
}

/// 点是否落在窗口边框周围的 resize 热区。热区同时覆盖窗口内外，保证从窗外靠近边缘时
/// HoverMonitor 能先恢复鼠标命中，再把真正的 resize mouseDown 交给 AppKit。
func isInResizeHotZone(point: CGPoint, frame: CGRect, thickness: CGFloat) -> Bool {
    guard frame.width > 1, frame.height > 1, thickness > 0 else { return false }
    let expanded = frame.insetBy(dx: -thickness, dy: -thickness)
    guard expanded.contains(point) else { return false }

    let distance = min(
        abs(point.x - frame.minX), abs(point.x - frame.maxX),
        abs(point.y - frame.minY), abs(point.y - frame.maxY)
    )
    return distance <= thickness
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
        let resizeZoneThicknessProvider: () -> CGFloat
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
                  resizeZoneThicknessProvider: @escaping () -> CGFloat = { 0 },
                  onChange: @escaping (HoverState) -> Void) {
        entries[id] = Entry(
            frameProvider: frameProvider,
            hotZoneProvider: hotZoneProvider,
            resizeZoneThicknessProvider: resizeZoneThicknessProvider,
            onChange: onChange,
            lastState: .none
        )
        startIfNeeded()
    }

    /// 最近一次派发给指定浮窗的状态。live resize 结束后用它立即恢复正确的 auto-hide 决策。
    func currentState(for id: UUID) -> HoverState { entries[id]?.lastState ?? .none }

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
        let modifiers = NSEvent.modifierFlags
        let optionHeld = modifiers.contains(.option)
        let commandHeld = modifiers.contains(.command)

        // 命中最上面的一个：除了窗口内部，也把边缘外侧的 resize 热区算作命中。
        // 按注册顺序无法判断 z 序，仍取面积最小的候选，维持现有重叠窗口体验。
        var hit: (id: UUID, area: CGFloat)?
        var resizeHits: [UUID: Bool] = [:]
        for (id, entry) in entries {
            guard let frame = entry.frameProvider() else { continue }
            let resizeHit = isInResizeHotZone(
                point: mouse,
                frame: frame,
                thickness: max(0, entry.resizeZoneThicknessProvider())
            )
            resizeHits[id] = resizeHit
            guard frame.contains(mouse) || resizeHit else { continue }
            let area = frame.width * frame.height
            if hit == nil || area < hit!.area { hit = (id, area) }
        }
        hoveredID = hit?.id

        // 逐个派发：状态没变化就不回调，避免每 100ms 触发一次动画
        for (id, entry) in entries {
            let hovering = id == hoveredID
            let overHotZone = hovering && (entry.hotZoneProvider()?.contains(mouse) ?? false)
            let state = HoverState(
                isHovering: hovering,
                isOverHotZone: overHotZone,
                isOverResizeZone: hovering && (resizeHits[id] ?? false),
                optionHeld: hovering ? optionHeld : false,
                commandHeld: hovering ? commandHeld : false
            )
            guard state != entry.lastState else { continue }
            entries[id]?.lastState = state
            entry.onChange(state)
        }
    }
}
