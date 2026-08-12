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
              let symbol = dlsym(handle, "_AXUIElementGetWindow") else { return nil }
        return unsafeBitCast(symbol, to: GetWindowID.self)
    }()

    /// 源窗口位于其它 Space、已不在 ScreenCaptureKit 缓存时，用 CGWindowList 补取 PID。
    static func ownerPID(of windowID: CGWindowID) -> pid_t? {
        guard let list = CGWindowListCopyWindowInfo(.optionIncludingWindow, windowID)
                as? [[String: Any]],
              let info = list.first(where: {
                  ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == windowID
              }),
              let number = info[kCGWindowOwnerPID as String] as? NSNumber else { return nil }
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

        let app = AXUIElementCreateApplication(pid)
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

    /// 读取指定窗口的实时 AX 标题。Electron 等应用的 CGWindowName 可能不会随文档切换及时更新。
    static func currentTitle(of windowID: CGWindowID, pid: pid_t) -> String? {
        guard Permissions.hasAccessibility else { return nil }
        let app = AXUIElementCreateApplication(pid)
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
