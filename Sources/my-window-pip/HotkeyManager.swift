import AppKit
import Carbon.HIToolbox

/// 全局热键管理（Carbon RegisterEventHotKey）。
///
/// 选择 Carbon 而非 CGEventTap 的原因：**完全不需要任何权限**，
/// 代价是无法注册 `fn` 组合键（那部分由可选的 `EventTapManager` 增强模式提供）。
final class HotkeyManager {
    static let shared = HotkeyManager()

    enum Action: UInt32 {
        case pip = 1
        case region = 2
        case closeAll = 3
    }

    /// 主线程回调
    var onTrigger: ((Action) -> Void)?

    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var eventHandler: EventHandlerRef?
    /// 注册失败（通常是被别的应用占用）的动作，供设置界面提示
    private(set) var failedActions: Set<Action> = []

    private static let signature: OSType = 0x4D57_5049  // 'MWPI'

    private init() {}

    // MARK: - 生命周期

    func start() {
        installHandlerIfNeeded()
        reload()
    }

    /// 读取最新偏好并重新注册全部热键。
    func reload() {
        unregisterAll()
        failedActions = []
        let prefs = Preferences.shared
        register(prefs.pipHotkey, for: .pip)
        register(prefs.regionHotkey, for: .region)
        register(prefs.closeAllHotkey, for: .closeAll)
    }

    func unregisterAll() {
        for (_, ref) in refs { UnregisterEventHotKey(ref) }
        refs.removeAll()
    }

    // MARK: - 注册

    @discardableResult
    private func register(_ config: HotkeyConfig, for action: Action) -> Bool {
        guard config.enabled else { return true }
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: Self.signature, id: action.rawValue)
        let status = RegisterEventHotKey(
            config.keyCode,
            config.carbonModifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &ref
        )
        guard status == noErr, let ref else {
            failedActions.insert(action)
            Log.warn("热键注册失败：\(config.displayString) status=\(status)")
            return false
        }
        refs[action.rawValue] = ref
        Log.info("热键已注册：\(config.displayString) → \(action)")
        return true
    }

    private func installHandlerIfNeeded() {
        guard eventHandler == nil else { return }
        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            hotkeyEventHandler,
            1,
            &spec,
            nil,
            &eventHandler
        )
        if status != noErr { Log.error("安装热键事件处理器失败：status=\(status)") }
    }

    fileprivate func handle(id: UInt32) {
        guard let action = Action(rawValue: id) else { return }
        Log.debug("热键触发：\(action)")
        onTrigger?(action)
    }

    /// 校验一组热键是否可用（设置界面录制后调用）：尝试注册再立刻注销。
    static func isAvailable(_ config: HotkeyConfig) -> Bool {
        var ref: EventHotKeyRef?
        let probeID = EventHotKeyID(signature: signature, id: 999)
        let status = RegisterEventHotKey(
            config.keyCode, config.carbonModifiers, probeID,
            GetApplicationEventTarget(), 0, &ref
        )
        if status == noErr, let ref {
            UnregisterEventHotKey(ref)
            return true
        }
        return false
    }
}

/// Carbon 事件回调必须是不捕获上下文的函数。
private func hotkeyEventHandler(
    _ callRef: EventHandlerCallRef?,
    _ event: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let event else { return OSStatus(eventNotHandledErr) }
    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hotKeyID
    )
    guard status == noErr else { return status }
    let id = hotKeyID.id
    DispatchQueue.main.async { HotkeyManager.shared.handle(id: id) }
    return noErr
}
