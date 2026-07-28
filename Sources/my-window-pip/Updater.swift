import AppKit
import CryptoKit

/// 一次 GitHub Release 查询的结果。
struct ReleaseInfo {
    let version: String    // 规范化版本号，如 "0.2.0"
    let tag: String        // 原始 tag，如 "v0.2.0"
    let dmgURL: URL?       // .dmg 直链
    let sha256URL: URL?    // .dmg.sha256 直链（用于校验下载完整性）
    let pageURL: URL?      // 发行说明页
}

/// 更新检查与下载。纯系统能力（URLSession + CryptoKit + NSWorkspace），无第三方依赖。
/// 除此之外本应用不发起任何网络请求。
///
/// v0.1.3 修复：旧实现用 `URLSession.shared` 的默认配置下载，空闲超时只有 60 秒，
/// 在慢链路上（实测本机拉 1.9 MB 的 DMG 要 80 秒以上）会直接超时失败；
/// 而且整个过程没有任何进度反馈，用户根本看不出在下载。
enum Updater {
    static let repo = "ljzxzxl/my-window-pip"
    private static let appName = "MyWindowPip"

    static var currentVersion: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0"
    }

    /// 是否正在下载更新（菜单栏据此显示进度）
    static var isDownloading: Bool { DownloadCoordinator.shared.isDownloading }
    /// 当前下载百分比，未知时为 nil
    static var downloadPercent: Int? { UpdateProgressWindow.percent }

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
        // 正在下载时不重复发起
        if isDownloading {
            showDownloadingNotice()
            return
        }
        fetchLatest { result in
            switch result {
            case let .failure(err):
                showAlert(
                    style: .warning,
                    title: L.t("检查更新失败", "Update check failed"),
                    message: describe(err)
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
        if isDownloading {
            showDownloadingNotice()
            return
        }

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = L.t("发现新版本 \(info.version)", "Version \(info.version) available")
        alert.informativeText = L.t(
            "当前版本 \(currentVersion)。下载过程会显示进度，完成后自动打开安装窗口，把 App 拖入「应用程序」替换即可。",
            "You have \(currentVersion). Progress is shown while downloading; the installer window opens "
                + "automatically afterwards — drag the app into Applications to replace it."
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

        if info.dmgURL != nil {
            if index == 0 {
                startDownload(info)
                return
            }
            index -= 1
        }
        if let page = info.pageURL, index == 0 {
            NSWorkspace.shared.open(page)
        }
    }

    // MARK: - 下载

    /// 开始下载并显示进度面板。
    static func startDownload(_ info: ReleaseInfo) {
        guard let dmgURL = info.dmgURL else { return }
        guard !isDownloading else {
            showDownloadingNotice()
            return
        }

        UpdateProgressWindow.show(version: info.version) {
            cancelDownload()
        }

        DownloadCoordinator.shared.start(
            url: dmgURL,
            destinationDirectory: try? updatesDirectory(),
            onProgress: { written, total in
                UpdateProgressWindow.update(bytesWritten: written, totalBytes: total)
            },
            onFinished: { result in
                switch result {
                case let .failure(error):
                    if (error as NSError).code == NSURLErrorCancelled {
                        Log.info("更新下载已取消")
                        UpdateProgressWindow.dismiss()
                        return
                    }
                    Log.error("更新下载失败：\(describe(error))")
                    UpdateProgressWindow.dismiss()
                    presentFailure(info, error: error)
                case let .success(file):
                    verifyThenOpen(file, info: info)
                }
            }
        )
    }

    static func cancelDownload() {
        DownloadCoordinator.shared.cancel()
        UpdateProgressWindow.dismiss()
    }

    /// 仅供 `--smoke-update` 使用：不弹任何窗口，直接跑下载链路。
    static func startDownloadForProbe(_ info: ReleaseInfo,
                                     onProgress: @escaping (Int64, Int64) -> Void,
                                     onFinished: @escaping (Result<URL, Error>) -> Void) {
        guard let dmgURL = info.dmgURL else {
            onFinished(.failure(makeError("no dmg asset")))
            return
        }
        DownloadCoordinator.shared.start(
            url: dmgURL,
            destinationDirectory: try? updatesDirectory(),
            onProgress: onProgress,
            onFinished: onFinished
        )
    }

    /// 校验 SHA256（有 .sha256 资产时）后打开 DMG。
    private static func verifyThenOpen(_ file: URL, info: ReleaseInfo) {
        guard let shaURL = info.sha256URL else {
            Log.debug("Release 未提供 .sha256 资产，跳过校验")
            finish(file, info: info)
            return
        }
        UpdateProgressWindow.update(bytesWritten: 1, totalBytes: 1)
        var req = URLRequest(url: shaURL, timeoutInterval: 20)
        req.setValue(appName, forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: req) { data, _, _ in
            let expected = data.flatMap { String(data: $0, encoding: .utf8) }?
                .split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" })
                .first
                .map(String.init)?
                .lowercased()

            DispatchQueue.main.async {
                guard let expected, expected.count == 64 else {
                    Log.warn("拿不到有效的 SHA256，跳过校验")
                    finish(file, info: info)
                    return
                }
                let actual = (try? sha256(ofFileAt: file))?.lowercased()
                if actual == expected {
                    Log.info("SHA256 校验通过")
                    finish(file, info: info)
                } else {
                    Log.error("SHA256 不一致：期望 \(expected) 实际 \(actual ?? "nil")")
                    try? FileManager.default.removeItem(at: file)
                    UpdateProgressWindow.dismiss()
                    presentFailure(info, error: makeError(
                        L.t("下载文件校验失败（内容不完整），请重试",
                            "Downloaded file failed checksum verification — please retry")
                    ))
                }
            }
        }.resume()
    }

    /// 打开 DMG 并引导替换。
    private static func finish(_ file: URL, info: ReleaseInfo) {
        cleanupOldPackages(keeping: file)
        UpdateProgressWindow.finish(message: L.t("下载完成，正在打开安装窗口…",
                                                 "Download complete — opening the installer…"))

        if !NSWorkspace.shared.open(file) {
            Log.warn("打开 DMG 失败，退回 Finder 中显示")
            NSWorkspace.shared.activateFileViewerSelecting([file])
        }

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = L.t("\(info.version) 已下载完成", "\(info.version) downloaded")
        alert.informativeText = L.t(
            """
            在打开的窗口里把 MyWindowPip 拖入「应用程序」覆盖旧版本即可。

            正在运行的旧版本会阻止覆盖，建议先退出本应用再拖动。
            """,
            """
            Drag MyWindowPip into Applications in the window that just opened to replace the old version.

            The running copy can block the replacement — quitting first is recommended.
            """
        )
        alert.addButton(withTitle: L.t("退出 MyWindowPip", "Quit MyWindowPip"))
        alert.addButton(withTitle: L.t("稍后退出", "Quit later"))
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            NSApp.terminate(nil)
        }
    }

    /// 下载失败：给出「重试 / 在浏览器中下载」两条出路。
    private static func presentFailure(_ info: ReleaseInfo, error: Error) {
        let ns = error as NSError
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L.t("下载失败", "Download failed")
        var detail = describe(error)
        if ns.code == NSURLErrorTimedOut || ns.code == NSURLErrorNetworkConnectionLost {
            detail += L.t("\n\n从 GitHub 下载偶尔会很慢，可以重试，或改用浏览器下载。",
                          "\n\nGitHub downloads can be slow — retry, or use your browser instead.")
        }
        alert.informativeText = detail
        alert.addButton(withTitle: L.t("重试", "Retry"))
        if info.pageURL != nil {
            alert.addButton(withTitle: L.t("在浏览器中下载", "Download in browser"))
        }
        alert.addButton(withTitle: L.t("取消", "Cancel"))

        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        let index = response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        if index == 0 {
            startDownload(info)
        } else if index == 1, let page = info.pageURL {
            NSWorkspace.shared.open(page)
        }
    }

    // MARK: - 网络：查询 Release

    /// 拉取最新 Release（回调在主线程）。
    static func fetchLatest(_ completion: @escaping (Result<ReleaseInfo, Error>) -> Void) {
        guard let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest") else {
            completion(.failure(makeError(L.t("更新地址无效", "Invalid update URL"))))
            return
        }
        var req = URLRequest(url: url, timeoutInterval: 15)
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
            var sha: URL?
            if let assets = obj["assets"] as? [[String: Any]] {
                for asset in assets {
                    guard let name = asset["name"] as? String,
                          let link = (asset["browser_download_url"] as? String)
                              .flatMap({ URL(string: $0) }) else { continue }
                    if name.hasSuffix(".dmg"), dmg == nil { dmg = link }
                    if name.hasSuffix(".dmg.sha256"), sha == nil { sha = link }
                }
            }
            done(.success(ReleaseInfo(version: normalize(tag), tag: tag,
                                      dmgURL: dmg, sha256URL: sha, pageURL: page)))
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

    // MARK: - 下载协调器

    /// 用专用会话 + delegate 下载，才能拿到进度并放宽超时。
    private final class DownloadCoordinator: NSObject, URLSessionDownloadDelegate {
        static let shared = DownloadCoordinator()

        private var task: URLSessionDownloadTask?
        private var onProgress: ((Int64, Int64) -> Void)?
        private var onFinished: ((Result<URL, Error>) -> Void)?
        private var destinationDirectory: URL?
        private var movedFile: URL?

        var isDownloading: Bool { task != nil }

        /// 慢链路友好配置：空闲超时 120s、整体上限 30 分钟、断网时等待恢复。
        private lazy var session: URLSession = {
            let cfg = URLSessionConfiguration.default
            cfg.timeoutIntervalForRequest = 120
            cfg.timeoutIntervalForResource = 1800
            cfg.waitsForConnectivity = true
            cfg.allowsExpensiveNetworkAccess = true
            cfg.httpAdditionalHeaders = ["User-Agent": Updater.appName]
            return URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
        }()

        var sessionDescription: String {
            "空闲超时 \(Int(session.configuration.timeoutIntervalForRequest))s，"
                + "整体上限 \(Int(session.configuration.timeoutIntervalForResource))s，"
                + "断网等待 \(session.configuration.waitsForConnectivity)"
        }

        func start(url: URL, destinationDirectory: URL?,
                   onProgress: @escaping (Int64, Int64) -> Void,
                   onFinished: @escaping (Result<URL, Error>) -> Void) {
            cancel()
            self.onProgress = onProgress
            self.onFinished = onFinished
            self.destinationDirectory = destinationDirectory
            self.movedFile = nil
            let task = session.downloadTask(with: url)
            self.task = task
            Log.info("开始下载更新：\(url.lastPathComponent)（\(sessionDescription)）")
            task.resume()
        }

        func cancel() {
            task?.cancel()
            task = nil
            onProgress = nil
            onFinished = nil
        }

        // MARK: URLSessionDownloadDelegate

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                        didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                        totalBytesExpectedToWrite: Int64) {
            let callback = onProgress
            DispatchQueue.main.async {
                callback?(totalBytesWritten, totalBytesExpectedToWrite)
            }
        }

        /// 临时文件只在本方法内有效，必须同步搬走。
        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                        didFinishDownloadingTo location: URL) {
            guard let directory = destinationDirectory else {
                movedFile = nil
                return
            }
            let name = downloadTask.originalRequest?.url?.lastPathComponent ?? "\(Updater.appName).dmg"
            let dest = directory.appendingPathComponent(
                name.hasSuffix(".dmg") ? name : "\(Updater.appName).dmg"
            )
            do {
                if FileManager.default.fileExists(atPath: dest.path) {
                    try FileManager.default.removeItem(at: dest)
                }
                try FileManager.default.moveItem(at: location, to: dest)
                movedFile = dest
            } catch {
                Log.error("更新包落盘失败：\(error.localizedDescription)")
                movedFile = nil
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            let finished = onFinished
            let file = movedFile
            self.task = nil
            onProgress = nil
            onFinished = nil
            movedFile = nil

            DispatchQueue.main.async {
                if let error {
                    finished?(.failure(error))
                } else if let file {
                    finished?(.success(file))
                } else {
                    finished?(.failure(Updater.makeError(
                        L.t("下载完成但无法保存文件", "Downloaded but could not save the file")
                    )))
                }
            }
        }
    }

    // MARK: - 工具

    /// 更新包存放目录：`~/Library/Application Support/MyWindowPip/Updates`（非 TCC 保护）。
    static func updatesDirectory() throws -> URL {
        let base = try FileManager.default.url(for: .applicationSupportDirectory,
                                               in: .userDomainMask, appropriateFor: nil, create: true)
        let dir = base.appendingPathComponent("\(appName)/Updates", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// 只保留最新一个更新包，避免长期堆积。
    private static func cleanupOldPackages(keeping keep: URL) {
        guard let dir = try? updatesDirectory(),
              let files = try? FileManager.default.contentsOfDirectory(
                  at: dir, includingPropertiesForKeys: nil) else { return }
        for file in files where file != keep && file.pathExtension == "dmg" {
            try? FileManager.default.removeItem(at: file)
        }
    }

    /// 流式计算 SHA256（1 MB 一块），避免把整个 DMG 读进内存。
    static func sha256(ofFileAt url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// 下载会话的配置描述，供 `--smoke-update` 打印确认参数生效。
    static var downloadSessionDescription: String { DownloadCoordinator.shared.sessionDescription }

    private static func normalize(_ tag: String) -> String {
        var s = tag
        if s.hasPrefix("v") || s.hasPrefix("V") { s.removeFirst() }
        return s
    }

    static func makeError(_ msg: String) -> NSError {
        NSError(domain: "Updater", code: -1, userInfo: [NSLocalizedDescriptionKey: msg])
    }

    /// 错误描述带上 domain/code，便于用户反馈时定位。
    static func describe(_ error: Error) -> String {
        let ns = error as NSError
        if ns.domain == "Updater" { return ns.localizedDescription }
        return "\(ns.localizedDescription)（\(ns.domain) \(ns.code)）"
    }

    /// 下载进行中又点了更新入口时的提示。
    private static func showDownloadingNotice() {
        let percentText = downloadPercent.map { "\($0)%" } ?? L.t("进行中", "in progress")
        showAlert(
            style: .informational,
            title: L.t("正在下载更新", "Update is downloading"),
            message: L.t("已完成 \(percentText)，进度面板里可以查看或取消。",
                         "\(percentText) done — check or cancel it in the progress panel.")
        )
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
