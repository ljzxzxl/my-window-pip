# MyWindowPip

把 **任意 macOS 窗口（或任意屏幕区域）实时镜像到一个永远置顶的小浮窗里**，用来长时间盯着看：跑得很久的编译、AI agent 的进度、日志、CI 面板、不支持原生画中画的网页视频。

底层用系统的 [ScreenCaptureKit](https://developer.apple.com/documentation/screencapturekit) 单窗口捕获（不录整屏），配合按应用记忆的帧率与静止检测，低帧率下 CPU 占用接近 0。

- 开源（MIT）、无账号、无联网（除你主动点「检查更新」）
- 通用二进制（Intel + Apple Silicon），macOS 14 及以上
- 只需 Xcode Command Line Tools 即可构建，不用装完整 Xcode

## 功能

**画中画**
- 一键把前台窗口变浮窗（默认 `⌃⌥P`），或从菜单栏窗口列表里挑
- 框选任意屏幕区域做画中画（默认 `⌃⌥⇧P`）；选区落在某个窗口内时自动改用窗口流，可跟随窗口移动、被遮挡也能捕获
- 多个浮窗同时运行，自动错位摆放，位置与宽度按应用记忆
- 浮窗置顶、可在所有 Space 与全屏应用之上显示、无边框、锁定宽高比

**缩放与平移**
- `Cmd` + 拖拽框选放大，`Cmd` + 双击复位
- 放大后滚轮平移，`Cmd` + 滚轮调倍率（以指针为锚），1×–20×
- 裁剪在捕获侧完成（`sourceRect`），放大后仍是原生像素，文字锐利，不是把小图插值放大

**省资源**
- 帧率按应用记忆：1 / 5 / 10 / 15 / 30 / 60 fps，终端与编辑器类应用首次默认 5 fps
- 静止检测：画面无变化自动降到 1 fps，一有变化立刻恢复
- 浮窗被完全遮挡或所在 Space 不可见时自动暂停拉流
- 改帧率、改分辨率、改裁剪都走 `SCStream.updateConfiguration`，不重建流、无黑帧

**交互**
- 自动隐藏 + 点击穿透：鼠标移上去浮窗淡出并暂停，可直接操作背后的内容
- 悬停浮出控制条：暂停、帧率、复位缩放、自动隐藏、静止检测、关闭
- 右键菜单包含全部操作（零权限模式下也能用全部功能）
- 源窗口最小化 → 显示占位并自动等待恢复；源窗口关闭 → 提示后自动关闭；源应用退出后重开 → 按应用 + 标题重连
- 检查更新（GitHub Releases）

## 快捷键

| 操作 | 默认快捷键 | 说明 |
|---|---|---|
| 画中画前台窗口 | `⌃⌥P` | 设置里可改 |
| 区域捕获 | `⌃⌥⇧P` | 设置里可改 |
| 关闭全部浮窗 | `⌃⌥\` | 设置里可改 |
| 区域框选中选中整个窗口 | 按住 `⌥` 单击 | 框选时 |
| 取消区域框选 | `⎋` 或右键 | 框选时 |
| 放大 / 缩小 | `Cmd` + 拖拽框选 / `Cmd` + 滚轮 | 鼠标在浮窗上 |
| 复位缩放 | `Cmd` + 双击 | 鼠标在浮窗上 |
| 平移 | 滚轮 | 放大后 |

**增强模式（可选，需要辅助功能权限）** 额外提供：

| 操作 | 快捷键 |
|---|---|
| 画中画前台窗口 / 区域捕获 | `fn`+`P` / `fn`+`⇧`+`P` |
| 调倍率 | 悬停时 `=` / `-` |
| 切帧率 | 悬停时 `F` |
| 切静止检测 | 悬停时 `D` |
| 显示 / 隐藏浮窗 | 悬停时轻点 `fn`（隐藏 60 秒后自动关闭） |
| 关闭浮窗 | 悬停时 `⌫` |

增强模式默认关闭。开启后只拦截上述按键，且悬停按键仅在鼠标位于浮窗范围内时生效，其余按键一律原样透传。

## 权限

| 权限 | 是否必需 | 用途 |
|---|---|---|
| 屏幕录制与系统录音 | **必需** | ScreenCaptureKit 捕获窗口画面 |
| 辅助功能 | 可选 | 仅增强模式（fn 组合键、悬停按键）需要 |

画面只在本机内存与显存中流转：不写磁盘、不上传、不做任何遥测。

> ad-hoc 签名的 App 每次重新构建二进制指纹都会变，macOS 可能重复索要屏幕录制权限。
> 改完代码重新构建后跑一次 `bash scripts/reset-permission.sh` 再重新授权即可；
> 也可以用 `bash scripts/build-app.sh --install` 固定装到 `/Applications`，路径稳定能减少反复授权。

## 帧率建议

| 场景 | 建议帧率 |
|---|---|
| 终端、日志、编译输出 | 1–5 fps |
| AI agent 进度、CI 面板、仪表盘 | 5–15 fps |
| 聊天、社区消息 | 10–15 fps |
| 视频、动画 | 30–60 fps |

## 实测占用

Intel i5 + macOS 26.5，1920×1080@2x 主屏，捕获 1920×993 的窗口，浮窗宽 640pt：

| 场景 | CPU | 常驻内存 |
|---|---|---|
| 1 路 · 1 fps | 0.1–0.4%（偶发峰值 3%） | 约 62 MB |
| 1 路 · 30 fps（内容变化不频繁） | 1.5–2.0% | 约 62 MB |
| 3 路并发 · 15 fps · 持续 70 秒 | 1.8–2.6% | 62.1 → 62.3 MB（无增长趋势） |

内存里约 55 MB 是 AppKit/ScreenCaptureKit 的框架基线，与浮窗数量基本无关。

## 构建

只需 Xcode Command Line Tools：

```bash
bash scripts/build-app.sh              # 生成 build/MyWindowPip.app（x86_64 + arm64）
bash scripts/build-app.sh --fast       # 只编当前架构，开发期更快
bash scripts/build-app.sh --debug      # 带 DEBUG 日志与几何自检
bash scripts/build-app.sh --install    # 顺带安装到 /Applications
open build/MyWindowPip.app
```

首次打开若提示无法验证开发者，在 Finder 里右键 App → 打开。

自检（不开界面，验证权限与整条捕获链路）：

```bash
./build/MyWindowPip.app/Contents/MacOS/my-window-pip --selftest
```

## 打包 DMG

```bash
bash scripts/build-app.sh
bash packaging/make-dmg.sh     # 生成 dist/MyWindowPip-<版本>.dmg + SHA256
```

推送 tag（如 `v0.1.0`，需与 `VERSION` 一致）会触发 GitHub Actions 自动构建并发布 Release。

## 已知边界

- 需要 macOS 14+：为了用 `SCStream.updateConfiguration` 平滑改帧率/分辨率/裁剪，不做 12.3–13 的兼容分支
- `fn` 组合键与「悬停按键」必须走事件监听，所以只能放在需要辅助功能权限的增强模式里
- 源窗口最小化时系统不再产出画面，只能显示占位并等待恢复（这是 macOS 的限制，不是 bug）
- 登录自启动依赖 `SMAppService`，ad-hoc 签名下可能失败，失败时会提示改用系统设置手动添加

## 暂未实现（v2 backlog）

- 音频跟随（架构已预留 `capturesAudio` 挂点）
- 增强对比度等画面滤镜（渲染层已预留滤镜挂点）
- 命令行控制已运行实例（`--app/--window/--zoom`）

## 许可证

MIT，见 `LICENSE`。灵感来自 [Pipiri](https://lowtechguys.com/pipiri/)，本项目是独立实现，不含其任何代码。
