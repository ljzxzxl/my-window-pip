import AppKit
import Darwin

/// 已验证 Chromium / Electron 源应用的兼容启动策略。
///
/// 只处理「源应用主动停止离屏 repaint」这类应用特例；CaptureEngine/PiPSession 不感知具体 App。
enum SourceAppCompatibility {
    struct Profile: Equatable {
        let bundleID: String
        let appName: String
        let launchArguments: [String]
        /// true = 已在本项目中实际 A/B 验证；false = 通过保守的 Chromium/Electron bundle 特征识别。
        let isVerified: Bool
    }

    /// 文件系统探测结果拆成纯数据，便于测试而不依赖本机安装了哪些 App。
    struct RuntimeStatus: Equatable {
        let appName: String
        let pid: pid_t
        let isCompatible: Bool
    }

    struct BundleSignature: Equatable {
        let hasElectronFramework: Bool
        let hasElectronAsar: Bool
        let hasRendererHelper: Bool
        let hasResourcesPak: Bool
        let hasICUData: Bool
    }

    enum RestartError: LocalizedError {
        case applicationURLUnavailable
        case terminationRejected
        case terminationTimedOut
        case launchFailed(String)
        case compatibilityArgumentsNotApplied

        var errorDescription: String? {
            switch self {
            case .applicationURLUnavailable:
                return L.t("找不到源应用的位置", "Could not locate the source application")
            case .terminationRejected:
                return L.t("源应用拒绝退出", "The source application refused to quit")
            case .terminationTimedOut:
                return L.t("等待源应用退出超时", "Timed out waiting for the source application to quit")
            case let .launchFailed(message):
                return message
            case .compatibilityArgumentsNotApplied:
                return L.t(
                    "源应用重新启动了，但 Chromium 兼容参数没有生效",
                    "The source app relaunched, but the Chromium compatibility argument was not applied"
                )
            }
        }
    }

    private static let compatibilityArguments = ["--disable-backgrounding-occluded-windows"]

    /// 已人工 A/B 验证：ChatGPT 与 Google Chrome 都会在 inactive Space 停止普通 UI repaint，
    /// 带该 Chromium 开关后可持续被 SCK 捕获。
    private static let verifiedProfiles: [Profile] = [
        Profile(
            bundleID: "com.openai.codex",
            appName: "ChatGPT",
            launchArguments: compatibilityArguments,
            isVerified: true
        ),
        Profile(
            bundleID: "com.google.Chrome",
            appName: "Google Chrome",
            launchArguments: compatibilityArguments,
            isVerified: true
        ),
    ]

    /// 动态框架探测只发生在创建 PiP 时；缓存避免反复遍历大 App bundle。
    private static var chromiumDetectionCache: [String: Bool] = [:]

    static var verifiedAppNames: [String] { verifiedProfiles.map(\.appName) }

    /// 设置页展示用：列出已验证应用当前主进程及兼容参数是否真实生效。
    static func verifiedRuntimeStatuses() -> [RuntimeStatus] {
        verifiedProfiles.compactMap { profile in
            guard let application = NSRunningApplication.runningApplications(
                withBundleIdentifier: profile.bundleID
            ).first(where: { !$0.isTerminated }) else { return nil }
            let pid = application.processIdentifier
            return RuntimeStatus(
                appName: profile.appName,
                pid: pid,
                isCompatible: isKnownCompatibilityLaunch(profile, pid: pid)
            )
        }
    }

    /// 仅返回明确 A/B 验证过的静态 profile，供测试/展示使用。
    static func profile(for bundleID: String?) -> Profile? {
        guard let bundleID else { return nil }
        return verifiedProfiles.first { $0.bundleID == bundleID }
    }

    /// 创建 PiP 时使用：已验证应用优先；其它应用则用保守 bundle 特征识别常见 Chromium/Electron。
    /// 这不是“所有 Electron 都一定有问题”的断言，只代表该启动开关在这类 runtime 中可用。
    static func profile(for application: NSRunningApplication) -> Profile? {
        guard let bundleID = application.bundleIdentifier else { return nil }
        if let verified = profile(for: bundleID) { return verified }
        guard let bundleURL = application.bundleURL,
              isChromiumLikeBundle(bundleURL, cacheKey: bundleID) else { return nil }
        return Profile(
            bundleID: bundleID,
            appName: application.localizedName
                ?? bundleURL.deletingPathExtension().lastPathComponent,
            launchArguments: compatibilityArguments,
            isVerified: false
        )
    }

    static func isChromiumLike(_ signature: BundleSignature) -> Bool {
        if signature.hasElectronFramework || signature.hasElectronAsar { return true }
        return signature.hasRendererHelper && signature.hasResourcesPak && signature.hasICUData
    }

    private static func isChromiumLikeBundle(_ bundleURL: URL, cacheKey: String) -> Bool {
        if let cached = chromiumDetectionCache[cacheKey] { return cached }
        let fm = FileManager.default
        let contents = bundleURL.appendingPathComponent("Contents", isDirectory: true)
        let frameworks = contents.appendingPathComponent("Frameworks", isDirectory: true)
        let resources = contents.appendingPathComponent("Resources", isDirectory: true)
        let electronFramework = frameworks.appendingPathComponent("Electron Framework.framework")
        let electronAsar = resources.appendingPathComponent("electron.asar")

        var rendererHelper = false
        var resourcesPak = false
        var icuData = false
        if let enumerator = fm.enumerator(
            at: frameworks,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) {
            for case let url as URL in enumerator {
                switch url.lastPathComponent {
                case let name where name.hasSuffix("Helper (Renderer).app"):
                    rendererHelper = true
                case "resources.pak":
                    resourcesPak = true
                case "icudtl.dat":
                    icuData = true
                default:
                    break
                }
                if rendererHelper && resourcesPak && icuData { break }
            }
        }

        let signature = BundleSignature(
            hasElectronFramework: fm.fileExists(atPath: electronFramework.path),
            hasElectronAsar: fm.fileExists(atPath: electronAsar.path),
            hasRendererHelper: rendererHelper,
            hasResourcesPak: resourcesPak,
            hasICUData: icuData
        )
        let result = isChromiumLike(signature)
        chromiumDetectionCache[cacheKey] = result
        return result
    }

    /// 当前进程是否真的带着兼容参数运行。PID 只是缓存键，命令行才是事实来源。
    ///
    /// - 旧版本曾使用 `sourceCompatibility.pid.*`，这里顺带迁移；
    /// - 浏览器自己 re-exec 导致 PID 变化时，只要参数仍在就自动更新记录；
    /// - PID 一样但参数不在时，清掉记录，避免把普通启动误认成兼容启动。
    static func isKnownCompatibilityLaunch(_ profile: Profile, pid: pid_t) -> Bool {
        let defaults = UserDefaults.standard
        let key = compatibilityPIDKey(profile.bundleID)
        let legacyKey = legacyCompatibilityPIDKey(profile.bundleID)

        let hasArguments = processHasCompatibilityArguments(pid: pid, profile: profile)
        if hasArguments {
            defaults.set(Int(pid), forKey: key)
            defaults.removeObject(forKey: legacyKey)
            return true
        }

        if defaults.integer(forKey: key) == Int(pid) {
            defaults.removeObject(forKey: key)
        }
        if defaults.integer(forKey: legacyKey) == Int(pid) {
            defaults.removeObject(forKey: legacyKey)
        }
        return false
    }

    /// 返回当前真正带兼容参数运行的主应用实例，并同步最新 PID 记录。
    static func compatibleRunningApplication(_ profile: Profile) -> NSRunningApplication? {
        for application in NSRunningApplication.runningApplications(withBundleIdentifier: profile.bundleID)
            where !application.isTerminated {
            if isKnownCompatibilityLaunch(profile, pid: application.processIdentifier) {
                return application
            }
        }
        return nil
    }

    static func restart(
        application: NSRunningApplication,
        profile: Profile,
        completion: @escaping (Result<NSRunningApplication, Error>) -> Void
    ) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let bundleURL = application.bundleURL else {
            completion(.failure(RestartError.applicationURLUnavailable))
            return
        }

        let oldPID = application.processIdentifier
        let launchArguments = launchArgumentsByAppendingCompatibility(
            processArguments: processArguments(pid: oldPID),
            compatibilityArguments: profile.launchArguments
        )
        guard application.terminate() else {
            completion(.failure(RestartError.terminationRejected))
            return
        }

        waitForTermination(pid: oldPID, deadline: .now() + 8) {
            // 直接执行 /usr/bin/open（不经过 shell），保留能读到的现有 argv，再追加兼容参数。
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            process.arguments = ["-na", bundleURL.path, "--args"] + launchArguments
            do {
                try process.run()
            } catch {
                completion(.failure(RestartError.launchFailed(error.localizedDescription)))
                return
            }
            waitForStableCompatibleApplication(
                profile: profile,
                deadline: .now() + 12,
                candidatePID: nil,
                stableTicks: 0,
                completion: completion
            )
        } onTimeout: {
            completion(.failure(RestartError.terminationTimedOut))
        }
    }

    private static func waitForStableCompatibleApplication(
        profile: Profile,
        deadline: DispatchTime,
        candidatePID: pid_t?,
        stableTicks: Int,
        completion: @escaping (Result<NSRunningApplication, Error>) -> Void
    ) {
        if let application = compatibleRunningApplication(profile) {
            let pid = application.processIdentifier
            let ticks = pid == candidatePID ? stableTicks + 1 : 1
            // 连续约 1 秒保持同一主 PID 且兼容参数仍在，才认定为最终稳定进程并记录。
            if ticks >= 4 {
                UserDefaults.standard.set(Int(pid), forKey: compatibilityPIDKey(profile.bundleID))
                Log.info("Chromium 兼容进程已稳定：\(profile.appName) pid=\(pid)")
                completion(.success(application))
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                waitForStableCompatibleApplication(
                    profile: profile,
                    deadline: deadline,
                    candidatePID: pid,
                    stableTicks: ticks,
                    completion: completion
                )
            }
            return
        }

        guard DispatchTime.now() < deadline else {
            completion(.failure(RestartError.compatibilityArgumentsNotApplied))
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            waitForStableCompatibleApplication(
                profile: profile,
                deadline: deadline,
                candidatePID: nil,
                stableTicks: 0,
                completion: completion
            )
        }
    }

    private static func processHasCompatibilityArguments(pid: pid_t, profile: Profile) -> Bool {
        guard let arguments = processArguments(pid: pid) else { return false }
        return profile.launchArguments.allSatisfy(arguments.contains)
    }

    /// 保留当前应用原有 argv（去掉 argv[0]），再在末尾追加缺失的 Chromium 兼容参数。
    /// 不过滤、不改写原有参数：外部脚本设置的地区、profile、proxy 等启动参数都应原样继承。
    static func launchArgumentsByAppendingCompatibility(
        processArguments: [String]?,
        compatibilityArguments: [String]
    ) -> [String] {
        var result = processArguments.map { Array($0.dropFirst()) } ?? []
        for argument in compatibilityArguments where !result.contains(argument) {
            result.append(argument)
        }
        return result
    }

    /// 读取同一用户进程的 argv（KERN_PROCARGS2），不调用 shell/ps。
    static func processArguments(pid: pid_t) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size: size_t = 0
        guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0,
              size > MemoryLayout<Int32>.size else { return nil }

        var bytes = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, u_int(mib.count), &bytes, &size, nil, 0) == 0 else { return nil }
        if size < bytes.count { bytes.removeSubrange(size..<bytes.count) }
        return parseProcessArgumentsBuffer(bytes)
    }

    /// KERN_PROCARGS2 缓冲解析拆成纯函数，便于单元测试。
    static func parseProcessArgumentsBuffer(_ bytes: [UInt8]) -> [String]? {
        guard bytes.count >= MemoryLayout<Int32>.size else { return nil }
        let argc: Int32 = bytes.withUnsafeBytes { raw in
            raw.loadUnaligned(as: Int32.self)
        }
        guard argc > 0, argc < 4096 else { return nil }

        var index = MemoryLayout<Int32>.size
        // 第一个 NUL 结尾字符串是 executable path。
        while index < bytes.count, bytes[index] != 0 { index += 1 }
        while index < bytes.count, bytes[index] == 0 { index += 1 }

        var result: [String] = []
        result.reserveCapacity(Int(argc))
        while index < bytes.count, result.count < Int(argc) {
            let start = index
            while index < bytes.count, bytes[index] != 0 { index += 1 }
            guard index > start else { break }
            let slice = bytes[start..<index]
            guard let value = String(bytes: slice, encoding: .utf8) else { return nil }
            result.append(value)
            while index < bytes.count, bytes[index] == 0 { index += 1 }
        }
        return result.count == Int(argc) ? result : nil
    }

    private static func waitForTermination(
        pid: pid_t,
        deadline: DispatchTime,
        completion: @escaping () -> Void,
        onTimeout: @escaping () -> Void
    ) {
        if NSRunningApplication(processIdentifier: pid) == nil {
            completion()
            return
        }
        guard DispatchTime.now() < deadline else {
            onTimeout()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            waitForTermination(
                pid: pid,
                deadline: deadline,
                completion: completion,
                onTimeout: onTimeout
            )
        }
    }

    private static func compatibilityPIDKey(_ bundleID: String) -> String {
        "chromiumCompatibility.pid.\(bundleID)"
    }

    private static func legacyCompatibilityPIDKey(_ bundleID: String) -> String {
        "sourceCompatibility.pid.\(bundleID)"
    }
}
