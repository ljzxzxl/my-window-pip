#!/bin/bash
# 重置本应用的隐私权限记录。
#
# 为什么需要：本项目用 ad-hoc 签名（codesign -s -），每次重新构建二进制的 cdhash 都会变，
# macOS 会认为「App 已被修改」，可能重复索要屏幕录制权限，或在系统设置里留下重复条目。
# 开发期改完代码重新构建后，跑一次本脚本再重新授权即可。
set -euo pipefail

BUNDLE_ID="com.ljzxzxl.mywindowpip"
APP_NAME="MyWindowPip"

echo "[reset-permission] 退出正在运行的 $APP_NAME ..."
pkill -x "$APP_NAME" 2>/dev/null || true

for service in ScreenCapture Accessibility; do
    if tccutil reset "$service" "$BUNDLE_ID" >/dev/null 2>&1; then
        echo "[reset-permission] 已重置 $service"
    else
        echo "[reset-permission] 重置 $service 失败（可能本就没有记录，可忽略）"
    fi
done

echo "[reset-permission] 完成。下次启动 App 时会重新弹出授权请求。"
echo "[reset-permission] 提示：用 scripts/build-app.sh --install 把 App 固定装到 /Applications，可减少反复授权。"
