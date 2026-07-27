import Foundation

/// 双语字符串工具。不使用 .lproj（swiftc 直编下资源管理不便），字符串内联双语。
enum L {
    static let isZH: Bool = {
        let lang = Locale.preferredLanguages.first ?? "en"
        return lang.hasPrefix("zh")
    }()

    static func t(_ zh: String, _ en: String) -> String { isZH ? zh : en }
}
