import AppKit
import Carbon.HIToolbox

/// 增强模式：用 `CGEventTap` 提供 Carbon 热键做不到的两件事
/// 1. `fn` 组合热键（Carbon 无法注册 fn 修饰键）
/// 2. 鼠标悬停在浮窗上时的裸键操作（`=` `-` `F` `D` `⌫`，以及轻点 `fn` 显隐）
///
/// 代价是需要「辅助功能」权限（要拦截并吞掉按键，只能用 `.defaultTap`）。
/// 默认关闭；未授权、创建失败或被系统禁用时都会自动降级，不影响零权限模式的正常使用。
final class EventTapManager {
    static let shared = EventTapManager()

    enum HoverKey {
        case zoomIn, zoomOut, cycleFPS, toggleIdleDetection, toggleHidden, close
    }

    /// fn 组合热键触发（主线程）
    var onGlobalTrigger: ((HotkeyManager.Action) -> Void)?
    /// 悬停裸键触发（主线程），参数为当前被悬停的会话 id
    var onHoverKey: ((HoverKey, UUID) -> Void)?

    private(set) var isEnabled = false
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    /// fn 轻点检测：按下时间戳 + 期间是否出现过其它按键
    private var fnDownAt: CFAbsoluteTime?
    private var fnCombinedWithKey = false
    private let fnTapMaxInterval: CFTimeInterval = 0.4

    private init() {}

    // MARK: - 开关

    /// 按偏好同步开关状态。返回最终是否处于启用状态。
    @discardableResult
    func syncWithPreferences() -> Bool {
        if Preferences.shared.enhancedMode {
            return enable()
        } else {
            disable()
            return false
        }
    }

    @discardableResult
    func enable() -> Bool {
        if isEnabled { return true }
        guard Permissions.hasAccessibility else {
            Log.warn("增强模式需要辅助功能权限，已保持关闭")
            return false
        }
        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.flagsChanged.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: eventTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            Log.error("创建事件监听失败，增强模式不可用")
            return false
        }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        runLoopSource = source
        isEnabled = true
        Log.info("增强模式已启用（fn 热键 + 悬停按键）")
        return true
    }

    func disable() {
        guard isEnabled else { return }
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes) }
        tap = nil
        runLoopSource = nil
        isEnabled = false
        fnDownAt = nil
        Log.info("增强模式已关闭")
    }

    /// 系统因超时或用户输入禁用了 tap 时重新启用（否则会静默失效）。
    fileprivate func reEnableAfterDisable() {
        guard let tap else { return }
        Log.warn("事件监听被系统禁用，正在恢复")
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    // MARK: - 事件处理（在 tap 回调线程调用，必须快速返回）

    /// - Returns: true 表示吞掉该事件
    fileprivate func handleKeyDown(keyCode: Int64, flags: CGEventFlags) -> Bool {
        fnCombinedWithKey = true

        let prefs = Preferences.shared
        // 1. fn 组合热键：fn + <pip 热键的主键>，加 Shift 则是区域捕获
        if flags.contains(.maskSecondaryFn),
           !flags.contains(.maskCommand), !flags.contains(.maskControl), !flags.contains(.maskAlternate),
           UInt32(keyCode) == prefs.pipHotkey.keyCode {
            let action: HotkeyManager.Action = flags.contains(.maskShift) ? .region : .pip
            DispatchQueue.main.async { [weak self] in self?.onGlobalTrigger?(action) }
            return true
        }

        // 2. 悬停裸键：仅当鼠标正悬停在某个浮窗上，且没有按下 ⌘⌃⌥ 时才拦截
        guard let hovered = HoverMonitor.shared.currentHovered(),
              !flags.contains(.maskCommand), !flags.contains(.maskControl),
              !flags.contains(.maskAlternate) else { return false }

        let key: HoverKey?
        switch Int(keyCode) {
        case kVK_ANSI_Equal, kVK_ANSI_KeypadPlus: key = .zoomIn
        case kVK_ANSI_Minus, kVK_ANSI_KeypadMinus: key = .zoomOut
        case kVK_ANSI_F: key = .cycleFPS
        case kVK_ANSI_D: key = .toggleIdleDetection
        case kVK_Delete, kVK_ForwardDelete: key = .close
        default: key = nil
        }
        guard let key else { return false }
        DispatchQueue.main.async { [weak self] in self?.onHoverKey?(key, hovered) }
        return true
    }

    /// 处理修饰键变化，用于识别「轻点 fn」。
    fileprivate func handleFlagsChanged(keyCode: Int64, flags: CGEventFlags) {
        // fn 键自身的 keyCode 为 kVK_Function(63)
        guard Int(keyCode) == kVK_Function else { return }
        if flags.contains(.maskSecondaryFn) {
            fnDownAt = CFAbsoluteTimeGetCurrent()
            fnCombinedWithKey = false
        } else {
            defer { fnDownAt = nil }
            guard let down = fnDownAt, !fnCombinedWithKey,
                  CFAbsoluteTimeGetCurrent() - down <= fnTapMaxInterval,
                  let hovered = HoverMonitor.shared.currentHovered() else { return }
            DispatchQueue.main.async { [weak self] in self?.onHoverKey?(.toggleHidden, hovered) }
        }
    }
}

/// CGEventTap 回调必须是不捕获上下文的 C 函数。
private func eventTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let manager = Unmanaged<EventTapManager>.fromOpaque(refcon).takeUnretainedValue()

    switch type {
    case .tapDisabledByTimeout, .tapDisabledByUserInput:
        manager.reEnableAfterDisable()
        return nil
    case .keyDown:
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        if manager.handleKeyDown(keyCode: keyCode, flags: event.flags) { return nil }
    case .flagsChanged:
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        manager.handleFlagsChanged(keyCode: keyCode, flags: event.flags)
    default:
        break
    }
    return Unmanaged.passUnretained(event)
}
