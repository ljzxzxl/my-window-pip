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
          FrameGate · IdleDetector      OverlayControlsView · PlaceholderView
            ↓
基础层    Models(契约) · Geo(坐标/缩放数学) · Preferences · Permissions · L10n · Log · Updater · LoginItem
```

单向数据流：

1. 输入层产生动作 → `SessionStore` 构造 `SessionRequest` → 新建 `PiPSession`
2. `PiPSession` 同时持有 `CaptureEngine` 与 `PiPWindowController`，两者互不引用
3. 帧：`SCStream` → 捕获串行队列 → `FrameGate.accept`（只放行 `.complete`）→ `IdleDetector.feed` → 主线程 → `AVSampleBufferDisplayLayer.enqueue`
4. 交互：视图手势 → `PiPWindowDelegate` → 改 `PiPSessionState` → `Geo.sourceRect` 算裁剪 → `CaptureEngine.retune`

## 关键约定

- **坐标系**：AppKit 全局（左下原点）、SCK（左上原点、相对 display）、源归一化（左上原点 0…1）。所有转换只能走 `Geo`，`--debug` 构建启动时会跑 `Geo.runSelfChecks()` 断言自检。
- **缩放不重建流**：改的是 `SCStreamConfiguration.sourceRect` + `width/height`，通过 `updateConfiguration` 下发；`CaptureEngine.restart()` 只作为兜底。
- **帧回调不碰 UI**：回调在 `com.ljzxzxl.mywindowpip.capture` 串行队列，任何 UI 操作都要 `DispatchQueue.main.async`。
- **不跨帧持有 `CMSampleBuffer`**，`queueDepth = 3`，宁丢帧不积压。
- **防镜中镜**：浮窗 `sharingType = .none`；窗口枚举过滤自身 App；区域捕获的显示器过滤器按 App 排除自己。
- **零权限优先**：任何功能都必须能在「只有屏幕录制权限」的前提下通过控制条或右键菜单完成；辅助功能权限只允许作为增强项。
- **不用系统 tooltip**：浮窗 level 是 `.screenSaver`(1000)，系统 tooltip 窗口层级更低会被压在浮窗后面，而且初始延迟不可调。所有浮窗内的提示统一走 `PiPWindowController.showHint(_:near:duration:)`，它用一个 `addChildWindow` 挂在浮窗上的**子窗口**承载（这样才能画到浮窗顶边之外、显示在图标上方），子窗口必须 `ignoresMouseEvents = true`。新增按钮时把提示文案登记到 `OverlayControlsView` 的 hint 映射里，不要再写 `toolTip`。
- **拖动是手动实现的**：`isMovableByWindowBackground = false`，由 `PiPContentView` 在 `mouseDragged` 里按位移 `setFrameOrigin`。原因是系统背景拖动会吞掉 `mouseUp`，拿不到干净的单击，而单击要用来「切回源应用」。改动手势时注意保持「拖动后触发 `pipDidMove` 持久化」与「跨屏 scale 变化后 retune」两条链路。
- **自动隐藏必须留逃生通道**：淡出后浮窗 `ignoresMouseEvents = true`，收不到任何鼠标事件。通道有四条：鼠标停在顶栏热区（`HoverMonitor` 的 `hotZoneProvider` + `PiPWindowController.barScreenFrame`）、按住 ⌥ 临时唤回、菜单栏每会话子菜单、开启时的 3 秒提示。改动自动隐藏逻辑时这几条不能破。
- **双语**：用户可见字符串一律 `L.t("中文", "English")`，不引入 `.lproj`。

## 常用命令

```bash
bash scripts/build-app.sh --fast --debug     # 开发期快速构建（单架构 + 日志 + 自检断言）
./build/MyWindowPip.app/Contents/MacOS/my-window-pip --selftest              # 权限与捕获链路自检
./build/MyWindowPip.app/Contents/MacOS/my-window-pip --smoke 10              # 自动开一路 PiP 跑 10 秒再退出
./build/MyWindowPip.app/Contents/MacOS/my-window-pip --smoke 60 --smoke-sessions 4   # 多路并发压测
./build/MyWindowPip.app/Contents/MacOS/my-window-pip --smoke-autohide        # 自动隐藏淡出/恢复回归
./build/MyWindowPip.app/Contents/MacOS/my-window-pip --smoke-bar             # 顶栏热区回归
./build/MyWindowPip.app/Contents/MacOS/my-window-pip --smoke-onboarding      # 首启引导浮层回归
bash scripts/reset-permission.sh             # 重建后重置 TCC 记录
```

> `--smoke-autohide` 与 `--smoke-bar` 会用 `CGWarpMouseCursorPosition` 短暂移动鼠标指针，
> 这是为了走真实的 `HoverMonitor` 轮询路径，跑完自动退出。

只想类型检查某几个文件（不连编整个 App）：

```bash
swiftc -typecheck -target x86_64-apple-macos14.0 \
  Sources/my-window-pip/Models.swift Sources/my-window-pip/Log.swift \
  Sources/my-window-pip/L10n.swift Sources/my-window-pip/Preferences.swift \
  Sources/my-window-pip/Permissions.swift Sources/my-window-pip/GeometryUtils.swift \
  Sources/my-window-pip/<你的文件>.swift
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
- 改帧率没反应：确认 `IdleDetector` 没把它压到 1 fps（`--debug` 日志里有「静止检测」记录）。
- 热键没反应：`HotkeyManager.failedActions` 非空说明被别的应用占用，设置页会提示；`fn` 组合键必须开增强模式。
- 增强模式突然失灵：系统会在负载高时禁用事件监听，`EventTapManager` 已监听 `tapDisabledByTimeout` 自动恢复，日志里能看到告警。
- 系统设置的「屏幕录制」列表里没有本应用：说明启动路径没走 `Permissions.ensureScreenRecording()`（它内部会先 `CGRequestScreenCaptureAccess()` 再补一次 `SCShareableContent` 探测，TCC 只有被真正请求过才会建条目）。
- 浮窗淡出后点不到任何东西：这是点击穿透的预期行为，按住 ⌥ 临时唤回，或从菜单栏该浮窗的子菜单关掉自动隐藏。
