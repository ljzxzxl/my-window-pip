<!--
  每次发版前更新本文件：它是 .github/workflows/release.yml 生成 Release 正文的内容来源。
  workflow 会在前面加版本标题、在后面附上 Full Changelog 比较链接。
-->

## 本版更新 / What's new

### 修复 Fixes

- **静止画面不再反复重建捕获流**：整屏 / 区域 PiP 在画面长时间静止，或源窗口处于 macOS 原生全屏 Space 时，ScreenCaptureKit 可能暂时停止送帧。旧版对这种情况每 2 秒无条件重建一次捕获流，而每次重建又会重置 stall watchdog 的计时，于是形成「静止 → 误判断流 → 每 2 秒重启」的循环，画面始终冻在最后一帧。现在改为最多 3 次主动重建（**2s / 4s / 8s 退避**），之后转入 **30 秒一次的低频健康检查**：显示器拔掉时静默等待、重新接回时立即恢复；任何真实帧到达都会重置退避预算。
- **Release 正文改为可读清单**：不再只有自动生成的 Full Changelog，修复内容、验证方式与下载校验说明会直接写在 Release 页面。

### 回归测试 Regression tests

- 新增 `DisplayStallRecoveryTests`：退避链、重启次数上限、真实帧恢复后的预算重置、显示器拔掉 / 重新接入、低频稀疏重启。
- CI 在 macOS 15 runner 上以 `swift test -Xswiftc -warnings-as-errors` 全量运行单元测试；发布包由 Release workflow 单独构建并校验固定身份签名。

### 下载与校验 Download & verify

- 下载 `.dmg`，用同目录下的 `.dmg.sha256` 校验完整性。
- 需要 macOS 14 或更高版本；首次使用请授予「屏幕录制」权限。
- 应用内「检查更新」走 GitHub Release 网页通道，不受未认证 API 配额（HTTP 403）影响。
