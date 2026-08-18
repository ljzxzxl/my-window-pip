# 开发者上手

## 分层与数据流

```
App 层    main.swift · AppDelegate · StatusBarController · SettingsWindowController · SelfTest
            ↓ 触发
输入层    HotkeyManager(Carbon 零权限) · EventTapManager(可选增强) · HoverMonitor(鼠标轮询)
          RegionSelectionController(全屏框选) · HotkeyRecorderView
            ↓ SessionRequest
会话层    SessionStore ──→ PiPSession（唯一同时实现 CaptureEngineDelegate 与 PiPWindowDelegate 的类）
            ↓                    ↓
捕获层    CaptureEngine        展示层  PiPWindowController(NSPanel)
          ShareableContentStore         PiPContentView(AVSampleBufferDisplayLayer)
          FrameGate · IdleDetector      RendererStallMonitor · OverlayControlsView · PlaceholderView
            ↓
基础层    Models(契约) · Geo(坐标/缩放数学) · Preferences · Permissions · L10n · Log · Updater · LoginItem
```

单向数据流：

1. 输入层产生动作 → `SessionStore` 构造 `SessionRequest` → 新建 `PiPSession`
2. `PiPSession` 同时持有 `CaptureEngine` 与 `PiPWindowController`，两者互不引用
3. 帧：`SCStream` → 捕获串行队列 → `FrameGate.accept`（只放行 `.complete`）→ `IdleDetector.feed` → 主线程 → `sampleBufferRenderer.enqueue`
4. 交互：视图手势 → `PiPWindowDelegate` → 改 `PiPSessionState` → `Geo.sourceRect` 算裁剪 → `CaptureEngine.retune`

## 关键约定

- **坐标系**：AppKit 全局（左下原点）、SCK（左上原点、相对 display）、源归一化（左上原点 0…1）。所有转换只能走 `Geo`，`--debug` 构建启动时会跑 `Geo.runSelfChecks()` 断言自检。
- **缩放不重建流**：改的是 `SCStreamConfiguration.sourceRect` + `width/height`，通过 `updateConfiguration` 下发；`CaptureEngine.restart()` 只作为兜底。
- **帧回调不碰 UI**：回调在 `com.ljzxzxl.mywindowpip.capture` 串行队列，任何 UI 操作都要 `DispatchQueue.main.async`。
- **不跨帧持有 `CMSampleBuffer`**，`queueDepth = 3`，宁丢帧不积压。
- **捕获健康与渲染健康分开监控**：`CaptureEngine` 的 watchdog 只判断 SCK 是否持续产帧；`RendererStallMonitor` 判断 renderer 是否持续接收帧。短暂 not-ready 正常丢帧，连续 2 秒则按 `flush → 重建 display layer → 重启捕获流` 分级恢复。macOS 14+ 只通过 `AVSampleBufferDisplayLayer.sampleBufferRenderer` 查询状态、enqueue 和 flush，不要混用 display layer 上已废弃的旧队列 API。
- **流不连续必须重置 renderer 时间线**：pause/resume、restart、源窗口重匹配、输出像素尺寸变化或 PTS 回退时，先 flush 旧队列并保留最后画面；普通平移/缩放且输出格式不变时不要无条件 flush，以免闪烁。
- **renderer 诊断只在事故时落盘**：每个会话用 `RendererDiagnostics` 在内存保留最近 64 条生命周期事件；确认卡流后生成 `R-XXXXXXXX` 编号并把现场快照写入 `~/Library/Logs/MyWindowPip/MyWindowPip.log`。普通 retune/帧状态不要逐条写 Release 日志；日志最多 2 MB + 一个 previous 文件，不得记录画面像素或上传。
- **只有 warn / error 落盘**：`Log.info` 里带着窗口标题（「新建窗口 PiP：<标题>」），正常使用不该把它留在磁盘上，所以 info / debug 只进控制台。事故快照本身是 `Log.warn`，排障能力不减。落盘走专用串行队列 `com.ljzxzxl.mywindowpip.log`——帧回调也会打日志，磁盘 I/O 不能占着锁卡住捕获队列或主线程。
- **自愈重启必须有上限**：`renderer 自愈耗尽 → restartCapture → captureWillRestart → prepareForCaptureDiscontinuity → stallMonitor.reset()` 是一条能自我循环的链，renderer 永久损坏时会无限重建 SCStream。`PiPSession` 用「90 秒内最多 2 次」限流，超限只打 `Log.error` 并提示用户关闭重开；恢复成功时经 `pipRendererDidRecover()` 清零。
- **防镜中镜**：浮窗 `sharingType = .none`；窗口枚举过滤自身 App；区域捕获的显示器过滤器按 App 排除自己。
- **零权限优先**：任何功能都必须能在「只有屏幕录制权限」的前提下通过控制条或右键菜单完成；辅助功能权限只允许作为增强项。
- **不用系统 tooltip**：浮窗 level 是 `.screenSaver`(1000)，系统 tooltip 窗口层级更低会被压在浮窗后面，而且初始延迟不可调。所有浮窗内的提示统一走 `PiPWindowController.showHint(_:near:duration:)`，它用一个 `addChildWindow` 挂在浮窗上的**子窗口**承载（这样才能画到浮窗顶边之外、显示在图标上方），子窗口必须 `ignoresMouseEvents = true`。新增按钮时把提示文案登记到 `OverlayControlsView` 的 hint 映射里，不要再写 `toolTip`。
- **拖动是手动实现的**：`isMovableByWindowBackground = false`，由 `PiPContentView` 在 `mouseDragged` 里按位移 `setFrameOrigin`。原因是系统背景拖动会吞掉 `mouseUp`，拿不到干净的单击，而单击要用来「切回源应用」。拖动会经过 `SessionStore` 的多窗口磁吸解析，只修正位置、不改尺寸，相邻浮窗的磁吸间距为 0。改动手势时注意保持「拖动后触发 `pipDidMove` 持久化」与「跨屏 scale 变化后 retune」两条链路。
- **自动隐藏必须留逃生通道**：淡出后浮窗 `ignoresMouseEvents = true`，收不到任何鼠标事件。通道有四条：鼠标停在顶栏热区（`HoverMonitor` 的 `hotZoneProvider` + `PiPWindowController.barScreenFrame`）、按住 ⌥ 临时唤回、菜单栏每会话子菜单、开启时的 3 秒提示。改动自动隐藏逻辑时这几条不能破。
- **双语**：用户可见字符串一律 `L.t("中文", "English")`，不引入 `.lproj`。
- **AX 调用一律带超时**：`AXUIElementCopyAttributeValue` 等是同步 IPC，会打到目标进程主线程，源 App 卡死时会连带冻住我们的主线程。AX 访问集中在 `SourceWindowActivator`，元素统一由内部的 `appElement(_:)` 创建（已 `AXUIElementSetMessagingTimeout(0.5)`）；不要在别处直接 `AXUIElementCreateApplication`。
- **窗口元数据只按需取，不做常驻轮询**：SCK 帧只有像素、不带标题。源窗口标题只在悬停浮出的顶栏与菜单里可见，所以刷新时机固定为三处——`handleHover` 的悬停上升沿、`PiPWindowController.menuNeedsUpdate`（经 `pipMenuWillOpen`）、`StatusBarController.menuWillOpen`（经 `SessionStore.refreshSourceTitles()`），每会话 0.5 秒节流。实测全量 `CGWindowListCopyWindowInfo(.optionAll)` 单次 2.0ms、单会话 AX 标题往返 1.6ms，2 秒轮询 3 路会话≈0.35% CPU 常驻，和 1fps 捕获同量级，不值得。
- **总览期间的窗口 frame 不可信**：调度中心 / Exposé 打开时 WindowServer 会把窗口等比缩小并内移，`SCWindow.frame` 与 `CGWindowListCopyWindowInfo` 的 bounds 报的都是**变换后**的矩形，而 `isOnScreen` 仍是 true（实测 1600×813 → 1092×555@(102,102)），AX 的 `kAXSize` 则不受影响。任何「按窗口尺寸更新几何」的代码都必须走 `Geo.trustedSourceSize(sampled:current:axSize:)`：有辅助功能权限时以 AX 为权威，没有权限时靠「两轴等比缩小」签名拒绝脏值。历史 bug 就是探测器在总览期间把裁剪框改小，退出后画面永久停在源窗口左上角局部放大。
- **zoom = 1 时不下发 `sourceRect`**：整窗且未放大时把 `sourceRect` 留成 `.zero`（SCK 语义 = 整个 filter 内容），既让画面天然跟随源窗口尺寸变化，也让几何采样出错时最坏只影响宽高比，不会裁歪画面。窗口内区域捕获与显示器区域捕获仍走显式裁剪。恢复流之后还有一次 1.2 秒的延时几何校正（要大于 `ShareableContentStore` 的 1 秒 TTL 才能拿到新采样）。
- **精确回源靠私有符号**：AX 没有公开的 `CGWindowID` 属性，`SourceWindowActivator` 用 `dlsym` 动态解析 `_AXUIElementGetWindow`。解析失败会打一条 `Log.warn` 并退到「标题唯一匹配」——同名窗口不唯一时绝不猜（历史 bug 就是回退到 `windows[0]` 抬错窗口）。`--smoke-activate` 会断言符号可用且能反查到捕获中的窗口。
- **发布包必须用固定身份签名**：TCC 保存的是 App 的 designated requirement。ad-hoc 签名没有证书可锚定，requirement 退化成钉死 cdhash（`designated => cdhash H"…"`），改一个字符重编就算「另一个 App」，用户升级后必须重新授权、还得手动删掉系统设置里那条失效记录。固定身份的 requirement 是 `identifier "com.ljzxzxl.mywindowpip" and certificate root = H"0741c799…"`，与二进制内容无关，因此同一张证书签出的所有版本共用一条授权记录。详见下面「发布签名」。

## 常用命令

```bash
bash scripts/build-app.sh --fast --debug     # 开发期快速构建（单架构 + 日志 + 自检断言）
swift test                                  # renderer 自愈与窗口磁吸测试（需完整 Xcode，仅 CLT 会报 no such module 'XCTest'）
./build/MyWindowPip.app/Contents/MacOS/my-window-pip --selftest              # 权限与捕获链路自检
./build/MyWindowPip.app/Contents/MacOS/my-window-pip --smoke 10              # 自动开一路 PiP 跑 10 秒再退出
./build/MyWindowPip.app/Contents/MacOS/my-window-pip --smoke 60 --smoke-sessions 4   # 多路并发压测
./build/MyWindowPip.app/Contents/MacOS/my-window-pip --smoke-autohide        # 自动隐藏淡出/恢复回归
./build/MyWindowPip.app/Contents/MacOS/my-window-pip --smoke-bar             # 顶栏热区回归
./build/MyWindowPip.app/Contents/MacOS/my-window-pip --smoke-onboarding      # 首启引导浮层回归
./build/MyWindowPip.app/Contents/MacOS/my-window-pip --smoke-activate        # 精确回源窗口 + 标题按需刷新回归
./build/MyWindowPip.app/Contents/MacOS/my-window-pip --smoke-mc              # 调度中心几何污染回归（会开合调度中心）
./build/MyWindowPip.app/Contents/MacOS/my-window-pip --smoke-renderer        # renderer 卡流状态机 + 计划性 flush 后仍能入队
./build/MyWindowPip.app/Contents/MacOS/my-window-pip --smoke-level           # 浮窗层级边界（statusBar(25) < 100 < popUpMenu(101)）
./build/MyWindowPip.app/Contents/MacOS/my-window-pip --smoke-update          # 更新链路回归（真实下载 + SHA256 校验）
bash scripts/reset-permission.sh             # 重建后重置 TCC 记录
```

> `--smoke-autohide` 与 `--smoke-bar` 会用 `CGWarpMouseCursorPosition` 短暂移动鼠标指针，
> 这是为了走真实的 `HoverMonitor` 轮询路径，跑完自动退出。

**两套编译路径分工**：`scripts/build-app.sh` 用 `swiftc` 直编（只装 Command Line Tools 的机器也能构建、能发版，是唯一的发布路径）；`Package.swift` 的 `MyWindowPipTests` 走 SwiftPM，只用来跑纯逻辑单测，**需要完整 Xcode**（XCTest 不随 CLT 提供），因此只挂在 `ci.yml`，不进 `release.yml`。新增源文件两边都会自动纳入（`Sources/my-window-pip/*.swift` 通配 + SwiftPM 目录约定），但新增编译选项或依赖要两处同步。跑不了 `swift test` 的机器用 `--smoke-renderer` 覆盖同一批状态机断言。

只想类型检查某几个文件（不连编整个 App）：

```bash
swiftc -typecheck -target x86_64-apple-macos14.0 \
  Sources/my-window-pip/Models.swift Sources/my-window-pip/Log.swift \
  Sources/my-window-pip/L10n.swift Sources/my-window-pip/Preferences.swift \
  Sources/my-window-pip/Permissions.swift Sources/my-window-pip/GeometryUtils.swift \
  Sources/my-window-pip/<你的文件>.swift
```

## 发布签名

`scripts/build-app.sh` 默认用自签证书「MyWindowPip Release Signing」（SHA-1 `0741C799718B712A1CC3211F3FA9B1A654B331DE`）签名，两个环境变量可覆盖：

| 变量 | 默认值 | 说明 |
|---|---|---|
| `SIGN_IDENTITY` | `MyWindowPip Release Signing` | 签名身份名称 |
| `SIGN_KEYCHAIN` | `~/Library/Keychains/mywindowpip-release.keychain-db` | 证书所在 keychain；文件存在时才追加 `--keychain` |

自签根不被系统信任，所以 `security find-identity -v -p codesigning` 报 0 个身份是正常的（`-v` 会把不受信任的过滤掉），去掉 `-v` 才能看到。**`codesign` 只认搜索列表里的钥匙串**，光传 `--keychain` 找不到身份——踩过这个坑，CI 脚本里因此有 `security list-keychains -d user -s` 一步。签名失败会自动回落 ad-hoc 并打印警告，构建末尾还会断言 requirement 里不含 `cdhash`。**回落后的包不要发布**。

> 历史：早先那张同名的「MyWindowPip Signing」（`C9D5F608…`，keychain `mywindowpip-signing.keychain-db`）是用钥匙串助理生成的，私钥导出会弹 GUI 确认框、没法在脚本里非交互导出，因此进不了 CI，已废弃不用。现在这张是 `openssl` 生成后带 `-A` 导入的，可随时重新导出。两张证书都没进过任何发布包，切换不影响用户。

CI（`.github/workflows/release.yml`）调用 `scripts/ci-import-cert.sh`，把 Secrets 里的 `.p12` 导进临时 keychain 后再构建，缺 `SIGNING_CERT_P12_BASE64` 直接失败，构建后再校验一次签名，最后 `if: always()` 删掉 keychain。一次性导出 `.p12` 的命令：

```bash
# 用 openssl 造一张十年期的代码签名证书（EKU 必须是 codeSigning）
openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
  -keyout key.pem -out cert.pem -subj "/CN=MyWindowPip Release Signing/O=MyWindowPip" \
  -addext "basicConstraints=critical,CA:false" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=critical,codeSigning"
# 打包成 p12（-legacy：macOS security 读不了 OpenSSL 3 的新默认加密）
openssl pkcs12 -export -legacy -inkey key.pem -in cert.pem \
  -name "MyWindowPip Release Signing" -out signing.p12
# 导入本机 keychain（-A 允许任何程序使用私钥，之后导出不再弹框）
security create-keychain -p "$KP" ~/Library/Keychains/mywindowpip-release.keychain-db
security import signing.p12 -k ~/Library/Keychains/mywindowpip-release.keychain-db \
  -P "$P12_PW" -A -T /usr/bin/codesign -f pkcs12
# 贴进 GitHub Secrets
openssl base64 -A -in signing.p12 | pbcopy   # → SIGNING_CERT_P12_BASE64
                                             # p12 密码 → SIGNING_CERT_PASSWORD
```

风险提示：**`.p12` 与密码必须离线备份**。本机的那份放在仓库根目录的 `signing-cert.local/`（含 `.p12`、cert.pem、p12 密码、keychain 密码、base64），已由 `.gitignore` 排除，**不要提交**；它是唯一一份，删仓库目录前先另存一份到别处。证书丢失或更换意味着 requirement 变化，所有用户都要重新授权一次（届时让他们点权限引导框里的「重置授权记录」）。自签证书不解决 Gatekeeper 首次拦截，那需要 Developer ID + 公证。

验证签名是否达标：

```bash
codesign --verify --strict build/MyWindowPip.app
codesign -d -r- build/MyWindowPip.app 2>&1 | grep 'designated =>'   # 不应出现 cdhash
```

## 加新功能时的落点

| 想做的事 | 该改哪里 |
|---|---|
| 新的画面滤镜（如增强对比度） | `PiPContentView` 的 layer filters + `PiPSessionState` 加字段 + 控制条按钮 |
| 音频跟随 | `CaptureEngine.makeConfiguration` 打开 `capturesAudio`，加 `.audio` 输出与播放器，`PiPSession` 里做静音开关 |
| 命令行控制已运行实例 | `main.swift` 解析参数 → 用 CFMessagePort/Distributed Notification 转发 → `SessionStore` 已有的创建入口 |
| 新的全局热键 | `HotkeyManager.Action` 加枚举 + `Preferences` 加配置 + 设置页加录制控件 |
| 新的浮窗操作 | `PiPWindowDelegate` 加方法 → `PiPSession` 实现 → 控制条/右键菜单/悬停按键三处入口都要接 |

## 排查提示

- 浮窗一片黑：先跑 `--selftest`。若权限正常但收不到帧，多半是源窗口最小化（系统不产帧）或流被 `FrameGate` 全过滤（画面完全静止）。
- 浮窗停在旧画面但源窗口仍在变化：恢复后会出现带 `R-XXXXXXXX` 的一次性提示；保存 `~/Library/Logs/MyWindowPip/MyWindowPip.log`（以及同目录的 `MyWindowPip.previous.log`）。搜索该编号可看到卡住前最近 64 条会话事件、retune 请求、PTS/像素尺寸、renderer 状态和分级恢复结果。不要只看 `CaptureEngine` 是否收帧——历史故障正是捕获持续正常、单个 renderer 却永久 not-ready。
- 提示「画面无法自动恢复，请关闭浮窗后重开」：说明 90 秒内已经重启过 2 次捕获流仍未恢复，限流生效、不再自动重启。日志里搜 `renderer 自愈已达上限` 能拿到前几轮的事故编号。
- 实时观察本地日志：`tail -f ~/Library/Logs/MyWindowPip/MyWindowPip.log`。只有 warn/error 与事故快照会落到这里（含窗口标题等运行元数据，不含任何画面像素、不上传）；想看逐帧细节用 `--debug` 构建看控制台输出。分享日志前按需脱敏。
- 改帧率没反应：确认 `IdleDetector` 没把它压到 1 fps（`--debug` 日志里有「静止检测」记录）。
- 热键没反应：`HotkeyManager.failedActions` 非空说明被别的应用占用，设置页会提示；`fn` 组合键必须开增强模式。
- 增强模式突然失灵：系统会在负载高时禁用事件监听，`EventTapManager` 已监听 `tapDisabledByTimeout` 自动恢复，日志里能看到告警。
- 系统设置的「屏幕录制」列表里没有本应用：说明启动路径没走 `Permissions.ensureScreenRecording()`（它内部会先 `CGRequestScreenCaptureAccess()` 再补一次 `SCShareableContent` 探测，TCC 只有被真正请求过才会建条目）。
- 升级后又被要求授权录屏：先 `codesign -d -r- <app> | grep designated`，出现 `cdhash` 就是签名回落成 ad-hoc 了（证书缺失或 keychain 锁着）。requirement 正常仍要求授权，说明本机残留旧版本的失效记录，点引导框里的「重置授权记录」或跑 `scripts/reset-permission.sh` 清一次。
- 浮窗淡出后点不到任何东西：这是点击穿透的预期行为，按住 ⌥ 临时唤回、或把鼠标停在顶栏热区，也可从菜单栏该浮窗的子菜单关掉自动隐藏。
- 更新下载失败：先跑 `--smoke-update` 看是网络还是逻辑问题。**踩过的坑**：`URLSession.shared` 默认空闲超时只有 60 秒，而本机拉 GitHub 的 1.9 MB DMG 实测要 80 秒以上，于是必定超时。现在 `Updater` 用专用会话（空闲 120s / 整体 1800s / `waitsForConnectivity`），下载走 `URLSessionDownloadDelegate` 以便上报进度；临时文件必须在 `didFinishDownloadingTo` 里**同步**搬走，否则回调返回后就被系统删了。
