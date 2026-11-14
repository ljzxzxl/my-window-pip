import Foundation

/// GitHub Releases「网页通道」的解析器（纯逻辑，不碰网络 / AppKit，便于回归测试）。
///
/// `api.github.com` 的未认证请求只有 **60 次/小时/IP**，且超限返回 **403**（不是 429）。
/// 同一出口 IP 下多人共用、或同一台机器反复调用时，检查更新会莫名变成「HTTP 403」。
/// 而 `github.com/.../releases.atom` 和 `.../releases/expanded_assets/<tag>` 是普通网页，
/// 不消耗这个配额，所以更新检查默认走这里；REST API 仅作为拿不到资产时的兜底。
enum ReleaseFeedParser {
    static let githubHost = "https://github.com"

    /// 从 `releases.atom` 里取最新一条 release 的 tag 与发行说明页。
    /// feed 按时间倒序，第一条 `releases/tag/<tag>` 链接就是最新版。
    /// 返回 nil 表示 feed 结构无法识别（此时调用方会回退到 REST API）。
    static func latestTag(from atomXML: String) -> (tag: String, pageURL: URL?)? {
        let pattern = #"href="(https://github\.com/[^"]*?/releases/tag/([^"/?#]+))""#
        guard let groups = firstMatch(pattern: pattern, in: atomXML), groups.count >= 3 else {
            return nil
        }
        let tag = groups[2]
        guard !tag.isEmpty else { return nil }
        return (tag, URL(string: groups[1]))
    }

    /// 从 `releases/expanded_assets/<tag>` 的 HTML 里取 DMG 与 `.dmg.sha256` 直链。
    /// href 一般是相对路径（`/owner/repo/releases/download/...`），也可能是绝对 URL；
    /// 两种都规范化成可直接下载的绝对 URL。
    static func assetLinks(from html: String) -> (dmg: URL?, sha256: URL?) {
        var dmg: URL?
        var sha256: URL?
        let pattern = #"href="([^"]*/releases/download/[^"]+)""#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return (nil, nil) }

        let range = NSRange(html.startIndex..., in: html)
        regex.enumerateMatches(in: html, range: range) { match, _, _ in
            guard let match, let r = Range(match.range(at: 1), in: html) else { return }
            let raw = String(html[r])
            let absolute: String
            if raw.hasPrefix("http://") || raw.hasPrefix("https://") {
                absolute = raw
            } else {
                absolute = Self.githubHost + (raw.hasPrefix("/") ? raw : "/" + raw)
            }
            guard let url = URL(string: absolute) else { return }
            if absolute.hasSuffix(".dmg.sha256") {
                if sha256 == nil { sha256 = url }
            } else if absolute.hasSuffix(".dmg") {
                if dmg == nil { dmg = url }
            }
        }
        return (dmg, sha256)
    }

    // MARK: - 私有

    /// 返回正则的第 0..n 个捕获组；未参与的组用空串占位，避免索引错位。
    private static func firstMatch(pattern: String, in text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
        else { return nil }
        return (0..<match.numberOfRanges).map { index -> String in
            guard let r = Range(match.range(at: index), in: text) else { return "" }
            return String(text[r])
        }
    }
}
