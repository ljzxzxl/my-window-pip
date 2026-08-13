#!/bin/bash
# 重置本应用的隐私权限记录。
#
# 为什么需要：TCC 保存授权时记的是 App 的 designated requirement。用固定身份（自签证书）
# 签名时 requirement 与二进制内容无关，授权可跨版本存活；但一旦回落到 ad-hoc 签名
# （证书缺失或 keychain 锁着），requirement 会退化成钉死 cdhash，每次重新构建都算「另一个 App」，
# 于是重复索要权限、系统设置里留下失效条目。此时跑一次本脚本再重新授权即可。
set -euo pipefail

BUNDLE_ID="com.ljzxzxl.mywindowpip"
APP_NAME="MyWindowPip"
EXEC="my-window-pip"   # 进程名是可执行文件名，不是 App 名，pkill -x 必须用这个

echo "[reset-permission] 退出正在运行的 $APP_NAME ..."
pkill -x "$EXEC" 2>/dev/null || true

for service in ScreenCapture Accessibility; do
    if tccutil reset "$service" "$BUNDLE_ID" >/dev/null 2>&1; then
        echo "[reset-permission] 已重置 $service"
    else
        echo "[reset-permission] 重置 $service 失败（可能本就没有记录，可忽略）"
    fi
done

echo "[reset-permission] 完成。下次启动 App 时会重新弹出授权请求。"
echo "[reset-permission] 提示：用 scripts/build-app.sh --install 把 App 固定装到 /Applications，可减少反复授权。"
