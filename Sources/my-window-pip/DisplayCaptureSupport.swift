import CoreGraphics
import Foundation

/// 一块可用于整屏捕获的显示器。
///
/// 只保存值类型，不持有 `NSScreen` / `SCDisplay`：屏幕参数变化后这些对象会失效，
/// 而菜单构建、热键目标选择和位置记忆都只需要稳定的 ID 与几何信息。
struct DisplayTarget: Equatable {
    var displayID: CGDirectDisplayID
    var name: String
    /// AppKit 全局坐标（左下原点，逻辑点）
    var frame: CGRect
    var isMain: Bool
    var isBuiltin: Bool

    var pointSize: CGSize { frame.size }

    var dimensions: String {
        "\(Int(frame.width.rounded()))×\(Int(frame.height.rounded()))"
    }
}

/// 整屏捕获的目标选择。纯逻辑，不触碰 AppKit，便于回归测试。
enum DisplayCaptureTarget {
    static func withID(_ id: CGDirectDisplayID,
                       in targets: [DisplayTarget]) -> DisplayTarget? {
        targets.first { $0.displayID == id }
    }

    /// 热键要捕获的显示器：
    /// 1. 上次从菜单栏选过的那块（仍然接着时优先复用）；
    /// 2. 否则第一块外接显示器（issue #12 的主要场景：朝向对方的外接屏）；
    /// 3. 否则第一块非主屏；
    /// 4. 只有一块屏幕时就用它。
    static func hotkeyTarget(in targets: [DisplayTarget],
                             lastUsedID: CGDirectDisplayID?) -> DisplayTarget? {
        guard !targets.isEmpty else { return nil }
        if let lastUsedID, let remembered = withID(lastUsedID, in: targets) {
            return remembered
        }
        if let external = targets.first(where: { !$0.isBuiltin }) { return external }
        if let secondary = targets.first(where: { !$0.isMain }) { return secondary }
        return targets.first(where: { $0.isMain }) ?? targets[0]
    }
}

/// 框选结束后决定用「显示器合成流」还是「单窗口流」。
///
/// 默认必须是显示器流：用户框选的是屏幕上的一块区域，理应看到该区域内所有内容，
/// 包括悬浮窗、实时字幕和菜单栏。若因为选区中心落在某个窗口内就切成单窗口流，
/// 全屏播放器（VLC / IINA）会把同屏的其它窗口全部吃掉（issue #13）。
enum RegionCapturePolicy {
    /// - `snapWindow`: ⌥ 单击，用户明确要求「整个窗口」，始终走窗口流；
    /// - `followsWindowByDefault`: 设置里的兼容开关，恢复旧版「选区跟随窗口」行为；
    /// - `hitWindowID`: 命中测试拿到的窗口，nil 时无论如何只能用显示器流。
    static func usesWindowStream(snapWindow: Bool, followsWindowByDefault: Bool,
                                 hitWindowID: CGWindowID?) -> Bool {
        guard hitWindowID != nil else { return false }
        return snapWindow || followsWindowByDefault
    }
}

/// `CGWindowListCopyWindowInfo` 返回的 bounds 字典解析。
///
/// 值可能是 CFNumber / NSNumber / CGFloat，直接 `as? [String: CGFloat]` 再强桥接成
/// `CFDictionary` 在部分系统上会失败（命中不稳定），极端情况下还可能触发异常。
/// 这里逐键读取并做类型检查，解析失败时返回 nil 让调用方跳过该窗口。
enum WindowBoundsParser {
    static func rect(from info: [String: Any]) -> CGRect? {
        func number(_ key: String) -> CGFloat? {
            guard let raw = info[key] else { return nil }
            if let v = raw as? CGFloat { return v }
            if let v = raw as? Double { return CGFloat(v) }
            if let v = raw as? Int { return CGFloat(v) }
            if let v = raw as? NSNumber { return CGFloat(v.doubleValue) }
            return nil
        }
        guard let x = number("X"), let y = number("Y"),
              let width = number("Width"), let height = number("Height"),
              width > 0, height > 0 else { return nil }
        return CGRect(x: x, y: y, width: width, height: height)
    }
}
