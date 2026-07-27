import Foundation
import ServiceManagement

/// 登录自启动封装（macOS 13+ 的 SMAppService.mainApp）。
/// 注意：ad-hoc 签名的 App 注册登录项可能失败，失败时调用方需回滚 UI 并提示。
enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    /// 设置登录项；成功返回 true，失败返回 false（调用方回滚 UI）。
    @discardableResult
    static func set(_ on: Bool) -> Bool {
        do {
            if on {
                if SMAppService.mainApp.status != .enabled { try SMAppService.mainApp.register() }
            } else {
                if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            }
            return true
        } catch {
            Log.warn("设置登录项失败：\(error.localizedDescription)")
            return false
        }
    }
}
