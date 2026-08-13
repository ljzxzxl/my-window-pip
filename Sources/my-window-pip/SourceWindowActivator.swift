import AppKit
import ApplicationServices
import Darwin

/// 激活 PiP 会话正在捕获的具体应用窗口。
///
/// Accessibility 提供窗口操作，却没有公开的 `CGWindowID` 属性。macOS 导出了
/// `_AXUIElementGetWindow`，这里动态解析符号：系统不支持时安全失败，再退到「标题唯一」匹配。
enum SourceWindowActivator {
    enum Result {
        case raised
        case applicationOnly
        case windowNotFound
        case activationFailed
        case applicationNotFound
    }

    private typealias GetWindowID = @convention(c) (
        AXUIElement, UnsafeMutablePointer<CGWindowID>
    ) -> AXError

    private static let getWindowID: GetWindowID? = {
        guard let handle = dlopen(nil, RTLD_LAZY),
              let symbol = dlsym(handle, "_AXUIElementGetWindow") else {
            Log.warn("AX 窗口 ID 符号不可用，精确回源降级为「标题唯一匹配」")
            return nil
        }
        return unsafeBitCast(symbol, to: GetWindowID.self)
    }()

    /// 精确匹配是否可用（私有符号是否解析成功），供 `--smoke-activate` 断言。
    static var isExactMatchAvailable: Bool { getWindowID != nil }

    /// AX 是同步 IPC，会打到目标进程的主线程；源 App 卡死时不能让它拖住我们的主线程。
    private static let messagingTimeout: Float = 0.5

    private static func appElement(_ pid: pid_t) -> AXUIElement {
        let element = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(element, messagingTimeout)
        return element
    }

    /// 单窗口查询：只问这一个 windowID，不拉全量窗口列表。
    static func windowInfo(of windowID: CGWindowID) -> [String: Any]? {
        guard let list = CGWindowListCopyWindowInfo(.optionIncludingWindow, windowID)
                as? [[String: Any]] else { return nil }
        return list.first {
            ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == windowID
        }
    }

    /// 源窗口位于其它 Space、已不在 ScreenCaptureKit 缓存时，用 CGWindowList 补取 PID。
    static func ownerPID(of windowID: CGWindowID) -> pid_t? {
        guard let number = windowInfo(of: windowID)?[kCGWindowOwnerPID as String] as? NSNumber
        else { return nil }
        return pid_t(number.int32Value)
    }

    static func activate(windowID: CGWindowID, pid: pid_t, fallbackTitle: String) -> Result {
        guard let runningApp = NSRunningApplication(processIdentifier: pid) else {
            return .applicationNotFound
        }

        // 没有辅助功能权限时，AppKit 只能激活应用，具体显示哪个窗口由应用自己决定。
        guard Permissions.hasAccessibility else {
            return runningApp.activate() ? .applicationOnly : .activationFailed
        }

        let app = appElement(pid)
        guard let windows = windows(of: app),
              let target = exactWindow(id: windowID, in: windows)
                ?? uniqueWindow(titled: fallbackTitle, in: windows) else {
            _ = runningApp.activate()
            return .windowNotFound
        }

        // 先恢复被最小化的源窗口。不同 App 对 AX 可写属性的支持不一，聚焦或抬起任一成功即算完成。
        AXUIElementSetAttributeValue(target, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        AXUIElementSetAttributeValue(target, kAXMainAttribute as CFString, kCFBooleanTrue)
        let firstFocus = AXUIElementSetAttributeValue(
            app, kAXFocusedWindowAttribute as CFString, target
        )
        _ = runningApp.activate()
        let raised = AXUIElementPerformAction(target, kAXRaiseAction as CFString)
        let finalFocus = AXUIElementSetAttributeValue(
            app, kAXFocusedWindowAttribute as CFString, target
        )

        if raised == .success || firstFocus == .success || finalFocus == .success {
            return .raised
        }
        return .activationFailed
    }

    /// 按需取指定窗口的当前标题：AX 优先，`CGWindowName` 兜底（只做一次单窗口查询）。
    ///
    /// 标题只在悬停顶栏与菜单里可见，所以由这些时机按需调用，不做常驻轮询。
    static func currentTitle(of windowID: CGWindowID) -> String? {
        guard let info = windowInfo(of: windowID) else { return nil }
        if let number = info[kCGWindowOwnerPID as String] as? NSNumber,
           let axTitle = currentTitle(of: windowID, pid: pid_t(number.int32Value)) {
            return axTitle
        }
        return info[kCGWindowName as String] as? String
    }

    /// 仅供 `--smoke-activate` 使用：确认捕获中的 windowID 能反查到 AX 窗口。
    static func canResolveExactWindow(id windowID: CGWindowID, pid: pid_t) -> Bool {
        guard Permissions.hasAccessibility,
              let windows = windows(of: appElement(pid)) else { return false }
        return exactWindow(id: windowID, in: windows) != nil
    }

    /// 读取指定窗口的实时 AX 标题。Electron 等应用的 CGWindowName 可能不会随文档切换及时更新。
    static func currentTitle(of windowID: CGWindowID, pid: pid_t) -> String? {
        guard Permissions.hasAccessibility else { return nil }
        let app = appElement(pid)
        guard let windows = windows(of: app),
              let target = exactWindow(id: windowID, in: windows) else { return nil }

        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            target, kAXTitleAttribute as CFString, &raw
        ) == .success else { return nil }
        return raw as? String
    }

    private static func windows(of app: AXUIElement) -> [AXUIElement]? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            app, kAXWindowsAttribute as CFString, &raw
        ) == .success else { return nil }
        return raw as? [AXUIElement]
    }

    private static func exactWindow(id: CGWindowID, in windows: [AXUIElement]) -> AXUIElement? {
        guard let getWindowID else { return nil }
        return windows.first { window in
            var candidate: CGWindowID = 0
            return getWindowID(window, &candidate) == .success && candidate == id
        }
    }

    /// 仅用于兼容性降级：标题为空或同名窗口不唯一时绝不猜测。
    private static func uniqueWindow(
        titled title: String, in windows: [AXUIElement]
    ) -> AXUIElement? {
        let wanted = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !wanted.isEmpty else { return nil }

        let matches = windows.filter { window in
            var raw: CFTypeRef?
            guard AXUIElementCopyAttributeValue(
                window, kAXTitleAttribute as CFString, &raw
            ) == .success,
                  let candidate = raw as? String else { return false }
            return candidate.trimmingCharacters(in: .whitespacesAndNewlines) == wanted
        }
        return matches.count == 1 ? matches[0] : nil
    }
}
