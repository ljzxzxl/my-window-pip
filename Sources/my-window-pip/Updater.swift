import AppKit

/// 一次 GitHub Release 查询的结果。
struct ReleaseInfo {
    let version: String    // 规范化版本号，如 "0.2.0"
    let tag: String        // 原始 tag，如 "v0.2.0"
    let dmgURL: URL?       // .dmg 直链
    let pageURL: URL?      // 发行说明页
}

/// 更新检查与引导下载。纯系统能力（URLSession + NSWorkspace），无第三方依赖。
/// 除此之外本应用不发起任何网络请求。
enum Updater {
    static let repo = "ljzxzxl/my-window-pip"
    private static let appName = "MyWindowPip"

    static var currentVersion: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0"
    }

    // MARK: - 对外入口

    /// 启动时静默检查：有新版才回调。
    static func checkSilently(_ onNewVersion: @escaping (ReleaseInfo) -> Void) {
        fetchLatest { result in
            guard case let .success(info) = result,
                  isNewer(info.version, than: currentVersion) else { return }
            Log.info("发现新版本 \(info.version)（当前 \(currentVersion)）")
            onNewVersion(info)
        }
    }

    /// 用户主动检查：无论结果都给反馈。
    static func checkInteractive() {
        fetchLatest { result in
            switch result {
            case let .failure(err):
                showAlert(
                    style: .warning,
                    title: L.t("检查更新失败", "Update check failed"),
                    message: err.localizedDescription
                )
            case let .success(info):
                if isNewer(info.version, than: currentVersion) {
                    presentUpdate(info)
                } else {
                    showAlert(
                        style: .informational,
                        title: L.t("已是最新版本", "You're up to date"),
                        message: L.t("当前版本 \(currentVersion)", "Current version \(currentVersion)")
                    )
                }
            }
        }
    }

    /// 弹出新版本提示并按用户选择下载。
    static func presentUpdate(_ info: ReleaseInfo) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = L.t("发现新版本 \(info.version)", "Version \(info.version) available")
        alert.informativeText = L.t(
            "当前版本 \(currentVersion)。下载完成后会自动打开安装窗口，把 App 拖入「应用程序」替换即可。",
            "You have \(currentVersion). The installer window opens automatically after download; "
                + "drag the app into Applications to replace it."
        )
        if info.dmgURL != nil {
            alert.addButton(withTitle: L.t("下载并安装", "Download & install"))
        }
        if info.pageURL != nil {
            alert.addButton(withTitle: L.t("查看发行说明", "Release notes"))
        }
        alert.addButton(withTitle: L.t("稍后", "Later"))

        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        var index = response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue

        if let dmg = info.dmgURL {
            if index == 0 {
                downloadAndOpen(dmg) { err in
                    if let err {
                        showAlert(style: .warning,
                                  title: L.t("下载失败", "Download failed"),
                                  message: err.localizedDescription)
                    }
                }
                return
            }
            index -= 1
        }
        if let page = info.pageURL, index == 0 {
            NSWorkspace.shared.open(page)
        }
    }

    // MARK: - 网络

    /// 拉取最新 Release（回调在主线程）。
    static func fetchLatest(_ completion: @escaping (Result<ReleaseInfo, Error>) -> Void) {
        guard let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest") else {
            completion(.failure(makeError(L.t("更新地址无效", "Invalid update URL"))))
            return
        }
        var req = URLRequest(url: url, timeoutInterval: 12)
        req.setValue(appName, forHTTPHeaderField: "User-Agent")   // GitHub API 要求带 UA
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        URLSession.shared.dataTask(with: req) { data, resp, err in
            func done(_ r: Result<ReleaseInfo, Error>) { DispatchQueue.main.async { completion(r) } }
            if let err { done(.failure(err)); return }
            guard let http = resp as? HTTPURLResponse else {
                done(.failure(makeError(L.t("无网络响应", "No response")))); return
            }
            guard http.statusCode == 200, let data else {
                done(.failure(makeError("HTTP \(http.statusCode)"))); return
            }
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = obj["tag_name"] as? String else {
                done(.failure(makeError(L.t("解析更新信息失败", "Failed to parse release info")))); return
            }
            let page = (obj["html_url"] as? String).flatMap { URL(string: $0) }
            var dmg: URL?
            if let assets = obj["assets"] as? [[String: Any]] {
                for a in assets where (a["name"] as? String)?.hasSuffix(".dmg") == true {
                    dmg = (a["browser_download_url"] as? String).flatMap { URL(string: $0) }
                    if dmg != nil { break }
                }
            }
            done(.success(ReleaseInfo(version: normalize(tag), tag: tag, dmgURL: dmg, pageURL: page)))
        }.resume()
    }

    /// 语义比较：latest 是否比 current 新。
    static func isNewer(_ latest: String, than current: String) -> Bool {
        let a = latest.split(separator: ".").map { Int($0) ?? 0 }
        let b = current.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    /// 下载 dmg 后用 NSWorkspace 打开（自动挂载并弹出安装窗）。
    /// 存到 Application Support（非 TCC 保护目录），避免写 ~/Downloads 被隐私权限拦截。
    static func downloadAndOpen(_ dmgURL: URL, completion: @escaping (Error?) -> Void) {
        URLSession.shared.downloadTask(with: dmgURL) { tmp, resp, err in
            func done(_ e: Error?) { DispatchQueue.main.async { completion(e) } }
            if let err { done(err); return }
            if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
                done(makeError(L.t("下载失败（HTTP \(http.statusCode)）", "Download failed (HTTP \(http.statusCode))")))
                return
            }
            guard let tmp else {
                done(makeError(L.t("下载失败：无临时文件", "Download failed: no temp file"))); return
            }
            do {
                let dir = try updatesDirectory()
                let name = dmgURL.lastPathComponent.hasSuffix(".dmg")
                    ? dmgURL.lastPathComponent : "\(appName).dmg"
                let dest = dir.appendingPathComponent(name)
                if FileManager.default.fileExists(atPath: dest.path) {
                    try FileManager.default.removeItem(at: dest)
                }
                try FileManager.default.moveItem(at: tmp, to: dest)
                NSWorkspace.shared.open(dest)
                done(nil)
            } catch {
                done(error)
            }
        }.resume()
    }

    // MARK: - 工具

    /// 更新包存放目录：`~/Library/Application Support/MyWindowPip/Updates`（非 TCC 保护）。
    private static func updatesDirectory() throws -> URL {
        let base = try FileManager.default.url(for: .applicationSupportDirectory,
                                               in: .userDomainMask, appropriateFor: nil, create: true)
        let dir = base.appendingPathComponent("\(appName)/Updates", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func normalize(_ tag: String) -> String {
        var s = tag
        if s.hasPrefix("v") || s.hasPrefix("V") { s.removeFirst() }
        return s
    }

    private static func makeError(_ msg: String) -> NSError {
        NSError(domain: "Updater", code: -1, userInfo: [NSLocalizedDescriptionKey: msg])
    }

    private static func showAlert(style: NSAlert.Style, title: String, message: String) {
        let alert = NSAlert()
        alert.alertStyle = style
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: L.t("好", "OK"))
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
