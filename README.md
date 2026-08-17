# MyWindowPip

<p align="center">
  <a href="https://github.com/ljzxzxl/my-window-pip/releases">
    <strong>Download MyWindowPip / 下载最新版 DMG</strong>
  </a>
</p>

<table>
  <tr>
    <td width="34%" align="center">
      <img src="docs/icon.png" alt="MyWindowPip app icon" width="180">
      <br>
      <strong>App Icon / 应用图标</strong>
    </td>
    <td width="66%" align="left">
      <strong>Picture-in-Picture for any macOS window</strong>
      <br><br>
      Mirror any window — or any screen region — into an always-on-top floating panel, built for
      watching things over long stretches: slow builds, AI agent progress, logs, CI dashboards,
      web videos with no native PiP.
      <br><br>
      <strong>macOS 任意窗口画中画</strong>
      <br><br>
      把任意窗口（或任意屏幕区域）实时镜像到一个永远置顶的小浮窗里，专门用来长时间盯着看：
      跑得很久的编译、AI agent 的进度、日志、CI 面板、不支持原生画中画的网页视频。
    </td>
  </tr>
</table>

Built on the system [ScreenCaptureKit](https://developer.apple.com/documentation/screencapturekit) to capture a single window (never the whole screen), with per-app frame rates and idle detection, so CPU usage stays close to zero at low frame rates. Universal binary for **Apple Silicon (arm64)** and **Intel (x64)**, macOS 14 or later. Open source (MIT), no account, no telemetry.

底层用系统的 [ScreenCaptureKit](https://developer.apple.com/documentation/screencapturekit) 单窗口捕获（不录整屏），配合按应用记忆的帧率与静止检测，低帧率下 CPU 占用接近 0。通用二进制，同时支持 **Apple Silicon (arm64)** 与 **Intel (x64)**，需要 macOS 14 及以上。开源（MIT）、无账号、无遥测。

[English](#english) | [中文](#中文)

## English

### Features

**Picture-in-Picture**
- Turn the frontmost window into a PiP with one hotkey (`⌃⌥P`), or pick a window from the menu bar list.
- Capture any screen region (`⌃⌥⇧P`); if the selection lands inside a window, a window stream is used instead, so it follows the window and keeps working when the window is covered.
- Multiple PiP windows at once, cascaded automatically; width remembered per app, while positions start fresh to avoid collisions between windows from the same app.
- Floating, borderless, aspect-locked, visible on all Spaces and above full-screen apps.

**Zoom & pan**
- `Cmd`-drag to zoom into a region, `Cmd`-scroll to change the factor (anchored at the pointer), `Cmd`-double-click to reset. Range 1×–20×.
- Scroll to pan when zoomed.
- Cropping happens on the capture side (`sourceRect`), so zooming keeps native pixels and stays sharp instead of interpolating a small image.

**Efficiency**
- Per-app frame rate: 1 / 5 / 10 / 15 / 30 / 60 fps; terminals and editors default to 5 fps.
- Idle detection drops to 1 fps when nothing changes and restores instantly when it does.
- Streaming pauses automatically when the PiP window is fully occluded or on an inactive Space.
- Frame rate, resolution and crop changes go through `SCStream.updateConfiguration` — no stream rebuild, no black frames.

**Interaction**
- A dimmed overlay with an arrow points at the menu bar icon on first launch, so it is obvious the app is running in the background; replay it any time from *Show Getting Started*.
- Click a PiP window to switch straight to its source app (optional); with Accessibility granted it identifies the source by window ID and raises that exact window, restoring it if it was minimized. Titles refresh on demand when the top bar or a menu appears — no background polling.
- Auto-hide with click-through: the window fades out and pauses when the pointer moves over it — but the **top bar stays usable**: rest the pointer on the bar and the window returns to full opacity so you can click buttons, drag it by the bar, or open the right-click menu, while the video area stays click-through.
- While faded you can also hold `⌥` to peek at the whole window, or turn auto-hide off from the window's menu bar submenu. The faded opacity is configurable in 5% steps (default 35%).
- Hover overlay controls: pause, frame rate, reset zoom, auto-hide, idle detection, close. Icons highlight on hover and the description appears instantly above the icon.
- Source minimized → placeholder and automatic resume; source closed → notice, then auto-close; source app relaunched → reconnect by app + title.
- Update check via GitHub Releases: downloads show a progress panel you can watch or cancel, the DMG is verified against the published SHA256, and on slow connections you can retry or switch to your browser with one click.

### Shortcuts

| Action | Default | Notes |
|---|---|---|
| PiP frontmost window | `⌃⌥P` | configurable |
| Capture region | `⌃⌥⇧P` | configurable |
| Close all | `⌃⌥\` | configurable |
| Grab a whole window | `⌥`-click | while selecting a region |
| Cancel selection | `⎋` or right-click | while selecting a region |
| Zoom | `Cmd`-drag / `Cmd`-scroll | pointer over PiP |
| Reset zoom | `Cmd`-double-click | pointer over PiP |
| Pan | scroll | when zoomed |
| Switch to the source window | click the PiP | can be disabled in Settings |
| Peek at a faded window | hold `⌥`, or rest the pointer on the top bar | while auto-hide has faded it |

Enhanced mode (optional, requires Accessibility) adds `fn`+`P` / `fn`+`⇧`+`P` hotkeys and hover keys: `=` / `-` zoom, `F` frame rate, `D` idle detection, tap `fn` to hide/show, `⌫` to close. It is off by default, only intercepts those keys, and everything else passes through untouched.

### Permissions

| Permission | Required | Purpose |
|---|---|---|
| Screen & System Audio Recording | **yes** | ScreenCaptureKit window capture |
| Accessibility | optional | exact source-window switching; Enhanced mode (fn hotkeys, hover keys) |

The system prompt appears on first launch and the app registers itself under *System Settings → Privacy & Security → Screen & System Audio Recording*, so you just flip the switch — no need to add it manually with the "+" button. macOS only applies the grant after a restart; the guide dialog has a "Relaunch app" button for that.

Release builds from v0.1.4 on are signed with a stable identity, so the grant **survives app updates**. If you are upgrading from v0.1.3 or earlier, macOS may ask once more because the old build left a stale record: click **Reset permission record** in the guide dialog, relaunch, and allow — later updates will keep it. Also drag the app into `/Applications` before running it; launching from the DMG or Downloads folder makes macOS randomise the path, which confuses the grant.

Frames stay in local memory and VRAM: nothing is written to disk, uploaded, or reported. The app makes no network requests other than update checks.

### Download

Grab the DMG from the [Releases page](https://github.com/ljzxzxl/my-window-pip/releases). One universal build covers both Apple Silicon and Intel Macs.

### Installing / first launch

Release builds are **signed with a self-signed certificate** (not notarized), so Gatekeeper blocks the first launch. Either:

```bash
xattr -cr /Applications/MyWindowPip.app
```

or right-click the app in Finder, choose "Open", then confirm.

Install it into `/Applications` and launch from there. A stable identity plus a stable path is what keeps the Screen Recording grant alive across updates; if the grant is nevertheless requested again, `bash scripts/reset-permission.sh` (or the in-app **Reset permission record** button) clears the stale TCC records.

### Frame rate guide

| Use case | Suggested |
|---|---|
| Terminals, logs, build output | 1–5 fps |
| AI agent progress, CI, dashboards | 5–15 fps |
| Chat, community feeds | 10–15 fps |
| Video, animation | 30–60 fps |

### Measured usage

Intel i5, macOS 26.5, 1920×1080@2x main display, capturing a 1920×993 window into a 640pt-wide PiP:

| Scenario | CPU | Resident memory |
|---|---|---|
| 1 stream · 1 fps | 0.1–0.4% (occasional 3% spike) | ~62 MB |
| 1 stream · 30 fps (low-motion content) | 1.5–2.0% | ~62 MB |
| 3 streams · 15 fps · 70 s | 1.8–2.6% | 62.1 → 62.3 MB (no upward trend) |

About 55 MB of that is the AppKit/ScreenCaptureKit baseline and is independent of the number of PiP windows.

### Build from source

Only the Xcode Command Line Tools are needed — full Xcode is not required.

```bash
bash scripts/build-app.sh              # build/MyWindowPip.app (x86_64 + arm64)
bash scripts/build-app.sh --fast       # current architecture only
bash scripts/build-app.sh --debug      # DEBUG logging + geometry self-checks
bash scripts/build-app.sh --install    # also install to /Applications
bash packaging/make-dmg.sh             # dist/MyWindowPip-<version>.dmg + SHA256
```

Built-in self-tests (no UI, useful after any change):

```bash
./build/MyWindowPip.app/Contents/MacOS/my-window-pip --selftest         # permissions + capture path
./build/MyWindowPip.app/Contents/MacOS/my-window-pip --smoke 10         # one PiP session end to end
./build/MyWindowPip.app/Contents/MacOS/my-window-pip --smoke-autohide   # auto-hide fade / restore
./build/MyWindowPip.app/Contents/MacOS/my-window-pip --smoke-bar        # top-bar hot zone
./build/MyWindowPip.app/Contents/MacOS/my-window-pip --smoke-onboarding # first-launch overlay
./build/MyWindowPip.app/Contents/MacOS/my-window-pip --smoke-activate   # exact source window + on-demand title
./build/MyWindowPip.app/Contents/MacOS/my-window-pip --smoke-mc         # Mission Control geometry regression
./build/MyWindowPip.app/Contents/MacOS/my-window-pip --smoke-update     # real download + SHA256 check
```

Pushing a `v*` tag (matching `VERSION`) builds the universal binary and publishes a GitHub Release.

### Repository layout

| Path | Purpose |
|---|---|
| `Sources/my-window-pip/` | All Swift sources: capture layer (`CaptureEngine`, `ShareableContentStore`, `FrameGate`, `IdleDetector`), presentation layer (`PiPWindowController`, `PiPContentView`, overlay views), session layer (`PiPSession`, `SessionStore`), input layer (hotkeys, event tap, hover monitor, region selection) and foundation (`Models`, `Geo`, `Preferences`, `Permissions`, `Updater`) |
| `Resources/` | `Info.plist` and the 1024×1024 icon source |
| `scripts/build-app.sh` | Builds both architectures with `swiftc`, assembles the `.app`, generates `AppIcon.icns`, signs with the fixed identity |
| `scripts/reset-permission.sh` | Resets this app's Screen Recording / Accessibility TCC records |
| `scripts/ci-import-cert.sh` | CI only: imports the signing certificate from Secrets into a temporary keychain |
| `packaging/make-dmg.sh` | Produces the DMG and its SHA256 |
| `docs/` | App icon and the [ONBOARDING](docs/ONBOARDING.md) handover doc (architecture, conventions, pitfalls) |
| `.github/workflows/release.yml` | Verifies tag vs `VERSION`, builds, publishes the Release |

### Notes

- Requires macOS 14+ so that `SCStream.updateConfiguration` can retune frame rate, resolution and crop smoothly; there is no 12.3–13 compatibility path.
- `fn` combinations and hover keys need an event tap, so they live in the optional Accessibility-gated enhanced mode. Everything else works with Screen Recording alone.
- While a source window is minimized the system produces no frames, so a placeholder is shown until it comes back — a macOS limitation, not a bug. Clicking the PiP un-minimizes the source window when Accessibility is granted.
- While Mission Control is open macOS scales every window down, so the PiP picture may briefly shrink; it returns to the full window as soon as you leave the overview.
- "Reset zoom" in the top bar refers to the **content zoom factor**, not the window size; it stays disabled until you zoom in with `Cmd`-drag or `Cmd`-scroll.
- Launch at login uses `SMAppService`, which can fail for ad-hoc signed apps; the app then points you to System Settings.
- Not implemented yet: audio follow, image filters such as contrast enhancement, and command-line control of a running instance. Hooks for all three are already in place.

### License

[MIT](LICENSE). Inspired by [Pipiri](https://lowtechguys.com/pipiri/); this is an independent implementation and contains none of its code.

## 中文

### 功能

**画中画**
- 一键把前台窗口变浮窗（`⌃⌥P`），或从菜单栏窗口列表里挑。
- 框选任意屏幕区域做画中画（`⌃⌥⇧P`）；选区落在某个窗口内时自动改用窗口流，可跟随窗口移动、被遮挡也能捕获。
- 多个浮窗同时运行，每次新建时自动错位摆放；宽度按应用记忆，位置不按应用持久化，避免同一应用的多个窗口重叠。
- 浮窗置顶、可在所有 Space 与全屏应用之上显示、无边框、锁定宽高比。

**缩放与平移**
- `Cmd` + 拖拽框选放大，`Cmd` + 滚轮以指针为锚调倍率，`Cmd` + 双击复位，范围 1×–20×。
- 放大后滚轮平移。
- 裁剪在捕获侧完成（`sourceRect`），放大后仍是原生像素，文字锐利，不是把小图插值放大。

**省资源**
- 帧率按应用记忆：1 / 5 / 10 / 15 / 30 / 60 fps，终端与编辑器类应用首次默认 5 fps。
- 静止检测：画面无变化自动降到 1 fps，一有变化立刻恢复。
- 浮窗被完全遮挡或所在 Space 不可见时自动暂停拉流。
- 改帧率、改分辨率、改裁剪都走 `SCStream.updateConfiguration`，不重建流、无黑帧。

**交互**
- 首次启动有一层遮罩 + 箭头引导指向菜单栏图标，明确告知「应用已在后台运行、入口在这里」；之后可从菜单栏「显示上手引导」重看。
- 单击浮窗直接切回源应用窗口（可关闭）；已授予辅助功能权限时会按窗口 ID 精确抬起对应窗口，源窗口已最小化也会一并恢复。浮窗标题在顶栏浮出、菜单打开时按需刷新，不做后台轮询。
- 自动隐藏 + 点击穿透：鼠标移上去浮窗淡出并暂停，可直接操作背后的内容；此时**顶栏仍然可用**——鼠标停在顶栏范围内浮窗就会恢复不透明，可以点按钮、按住顶栏拖动窗口、调出右键菜单，画面区域依旧穿透。
- 淡出后也可以按住 `⌥` 临时唤回整窗，或在菜单栏的浮窗子菜单里关掉自动隐藏。淡出透明度可调，5% 一档（默认 35%）。
- 悬停浮出控制条：暂停、帧率、复位缩放、自动隐藏、静止检测、关闭；图标有悬停高亮，说明文字立刻显示在图标上方。
- 源窗口最小化 → 显示占位并自动等待恢复；源窗口关闭 → 提示后自动关闭；源应用退出后重开 → 按应用 + 标题重连。
- 检查更新（GitHub Releases）：下载有独立进度面板可看可取消，自动用 Release 里的 SHA256 校验完整性；网络慢导致失败时可一键重试或改用浏览器下载。

### 快捷键

| 操作 | 默认快捷键 | 说明 |
|---|---|---|
| 画中画前台窗口 | `⌃⌥P` | 设置里可改 |
| 区域捕获 | `⌃⌥⇧P` | 设置里可改 |
| 关闭全部浮窗 | `⌃⌥\` | 设置里可改 |
| 框选时选中整个窗口 | 按住 `⌥` 单击 | 区域框选中 |
| 取消区域框选 | `⎋` 或右键 | 区域框选中 |
| 放大 / 缩小画面 | `Cmd` + 拖拽框选 / `Cmd` + 滚轮 | 鼠标在浮窗上 |
| 复位画面倍率 | `Cmd` + 双击 | 鼠标在浮窗上 |
| 平移画面 | 滚轮 | 放大后 |
| 切换到源应用窗口 | 单击浮窗 | 可在设置里关闭 |
| 临时唤回已淡出的浮窗 | 按住 `⌥`，或把鼠标停在顶栏 | 开了自动隐藏时 |

增强模式（可选，需要辅助功能权限）额外提供 `fn`+`P` / `fn`+`⇧`+`P` 热键，以及鼠标悬停时的裸键：`=` / `-` 调倍率、`F` 切帧率、`D` 切静止检测、轻点 `fn` 显隐、`⌫` 关闭。默认关闭；开启后只拦截上述按键，其余按键一律原样透传。

### 权限

| 权限 | 是否必需 | 用途 |
|---|---|---|
| 屏幕录制与系统录音 | **必需** | ScreenCaptureKit 捕获窗口画面 |
| 辅助功能 | 可选 | 精确切换到源窗口；增强模式（fn 组合键、悬停按键） |

首次启动会弹出系统的屏幕录制授权框，本应用会自动出现在「系统设置 → 隐私与安全性 → 屏幕录制与系统录音」列表里，**直接打开开关即可，不需要手动点加号添加**。macOS 要求授权后重启应用才生效，引导框里有「重新启动应用」按钮。

v0.1.4 起发布包使用固定签名身份，**授权可以跨版本存活**，更新后不再重新索要。从 v0.1.3 及更早版本升级上来时，因为旧包留下的是失效记录，还会被要求授权一次：在引导框里点**「重置授权记录」**→ 重启 → 允许，之后所有更新都会保留。另外请把 App 拖进 `/Applications` 再运行——直接从 DMG 或下载目录启动会被 macOS 随机化路径，同样会干扰授权。

画面只在本机内存与显存中流转：不写磁盘、不上传、不做任何遥测；除主动检查更新外不发起任何网络请求。

### 下载

到 [Releases 页面](https://github.com/ljzxzxl/my-window-pip/releases)下载 DMG，一个通用二进制同时支持 Apple Silicon 与 Intel Mac。

### 安装与首次启动

发布版本使用**自签证书签名**（未经过 Apple 公证），首次启动会被 Gatekeeper 拦截。两种方式任选其一：

```bash
xattr -cr /Applications/MyWindowPip.app
```

或者在 Finder 里右键点击 App 选择「打开」并确认。

请安装到 `/Applications` 并从那里启动：固定的签名身份 + 固定的路径，才能让屏幕录制授权跨版本存活。万一仍被要求重新授权，跑一次 `bash scripts/reset-permission.sh`（或用引导框里的**「重置授权记录」**按钮）清掉旧记录即可。

### 帧率建议

| 场景 | 建议帧率 |
|---|---|
| 终端、日志、编译输出 | 1–5 fps |
| AI agent 进度、CI 面板、仪表盘 | 5–15 fps |
| 聊天、社区消息 | 10–15 fps |
| 视频、动画 | 30–60 fps |

### 实测占用

Intel i5 + macOS 26.5，1920×1080@2x 主屏，捕获 1920×993 的窗口，浮窗宽 640pt：

| 场景 | CPU | 常驻内存 |
|---|---|---|
| 1 路 · 1 fps | 0.1–0.4%（偶发峰值 3%） | 约 62 MB |
| 1 路 · 30 fps（内容变化不频繁） | 1.5–2.0% | 约 62 MB |
| 3 路并发 · 15 fps · 持续 70 秒 | 1.8–2.6% | 62.1 → 62.3 MB（无增长趋势） |

内存里约 55 MB 是 AppKit/ScreenCaptureKit 的框架基线，与浮窗数量基本无关。

### 从源码构建

只需 Xcode Command Line Tools，不用装完整 Xcode。

```bash
bash scripts/build-app.sh              # 生成 build/MyWindowPip.app（x86_64 + arm64）
bash scripts/build-app.sh --fast       # 只编当前架构，开发期更快
bash scripts/build-app.sh --debug      # 带 DEBUG 日志与几何自检
bash scripts/build-app.sh --install    # 顺带安装到 /Applications
bash packaging/make-dmg.sh             # 生成 dist/MyWindowPip-<版本>.dmg + SHA256
```

内置自检（不开界面，改完代码跑一遍最省事）：

```bash
./build/MyWindowPip.app/Contents/MacOS/my-window-pip --selftest         # 权限与捕获链路
./build/MyWindowPip.app/Contents/MacOS/my-window-pip --smoke 10         # 一路 PiP 端到端
./build/MyWindowPip.app/Contents/MacOS/my-window-pip --smoke-autohide   # 自动隐藏淡出/恢复
./build/MyWindowPip.app/Contents/MacOS/my-window-pip --smoke-bar        # 顶栏热区
./build/MyWindowPip.app/Contents/MacOS/my-window-pip --smoke-onboarding # 首启引导浮层
./build/MyWindowPip.app/Contents/MacOS/my-window-pip --smoke-activate   # 精确回源窗口 + 标题按需刷新
./build/MyWindowPip.app/Contents/MacOS/my-window-pip --smoke-mc         # 调度中心几何污染回归
./build/MyWindowPip.app/Contents/MacOS/my-window-pip --smoke-update     # 真实下载 + SHA256 校验
```

推送与 `VERSION` 一致的 `v*` tag 会自动构建通用二进制并发布 Release。

### 仓库结构

| 路径 | 用途 |
|---|---|
| `Sources/my-window-pip/` | 全部 Swift 源码：捕获层（`CaptureEngine`、`ShareableContentStore`、`FrameGate`、`IdleDetector`）、展示层（`PiPWindowController`、`PiPContentView`、控制条与占位视图）、会话层（`PiPSession`、`SessionStore`）、输入层（热键、事件监听、悬停轮询、区域框选）、基础层（`Models`、`Geo`、`Preferences`、`Permissions`、`Updater`） |
| `Resources/` | `Info.plist` 与 1024×1024 图标源文件 |
| `scripts/build-app.sh` | 用 `swiftc` 编双架构、组装 `.app`、生成 `AppIcon.icns`、用固定身份签名 |
| `scripts/reset-permission.sh` | 重置本应用的屏幕录制 / 辅助功能 TCC 记录 |
| `scripts/ci-import-cert.sh` | 仅 CI 用：把 Secrets 里的签名证书导入临时 keychain |
| `packaging/make-dmg.sh` | 打包 DMG 并生成 SHA256 |
| `docs/` | 应用图标与[交接文档 ONBOARDING](docs/ONBOARDING.md)（架构、约定、踩过的坑） |
| `.github/workflows/release.yml` | 校验 tag 与 `VERSION` 一致后构建并发布 Release |

### 说明

- 需要 macOS 14+：为了用 `SCStream.updateConfiguration` 平滑改帧率/分辨率/裁剪，不做 12.3–13 的兼容分支。
- `fn` 组合键、「悬停按键」与精确切换到具体源窗口需要辅助功能权限；未授权时，单击浮窗仍会激活源应用，但由应用决定显示哪个窗口。
- 源窗口最小化时系统不再产出画面，只能显示占位并等待恢复（这是 macOS 的限制，不是 bug）；已授予辅助功能权限时，单击浮窗会把最小化的源窗口恢复出来。
- 调度中心（Mission Control）打开时 macOS 会把所有窗口等比缩小，浮窗画面可能暂时缩小；退出总览即恢复成完整窗口。
- 顶栏的「复位缩放」指的是**画面放大倍率**，与浮窗窗口大小无关；没有用 `Cmd` 拖拽或 `Cmd` 滚轮放大过画面时它是灰色不可用的。
- 登录自启动依赖 `SMAppService`，ad-hoc 签名下可能失败，失败时会提示改用系统设置手动添加。
- 暂未实现：音频跟随、增强对比度等画面滤镜、命令行控制已运行实例。三者的架构挂点都已预留。

### 许可证

[MIT](LICENSE)。灵感来自 [Pipiri](https://lowtechguys.com/pipiri/)，本项目是独立实现，不含其任何代码。
