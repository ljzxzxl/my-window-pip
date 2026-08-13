#!/bin/bash
# CI 专用：把 base64 编码的 .p12 证书导入临时钥匙串，供 codesign 使用。
#
# 环境变量：
#   P12          - .p12 文件的 base64（GitHub Secret: SIGNING_CERT_P12_BASE64）
#   P12_PASSWORD - .p12 的导出密码（GitHub Secret: SIGNING_CERT_PASSWORD）
#
# 成功后把 SIGN_KEYCHAIN 写进 $GITHUB_ENV，后续 build-app.sh 会用它签名。
# 发布包必须用固定身份签名（TCC 记的是 designated requirement），所以这里缺证书就直接失败，
# 不允许静默回落 ad-hoc。
set -euo pipefail

: "${P12:=}"
: "${P12_PASSWORD:=}"
TMP="${RUNNER_TEMP:-/tmp}"
CERT="$TMP/cert.p12"
KEYCHAIN="$TMP/signing.keychain-db"

if [ -z "$P12" ]; then
    echo "::error::缺少 Secret SIGNING_CERT_P12_BASE64，发布包必须用固定身份签名"
    exit 1
fi

# macOS 自带的 base64 不认 --decode 这类长选项，统一用 openssl 解码
printf '%s' "$P12" | tr -d '\n\r ' | openssl base64 -d -A > "$CERT"
SIZE="$(wc -c < "$CERT" | tr -d ' ')"
echo "[import-cert] 解码后 p12 大小 ${SIZE} 字节"
if [ "$SIZE" -lt 500 ]; then
    echo "::error::p12 解码结果只有 ${SIZE} 字节，SIGNING_CERT_P12_BASE64 可能没贴全"
    exit 1
fi

KP="$(uuidgen)"
rm -f "$KEYCHAIN"
security create-keychain -p "$KP" "$KEYCHAIN"
security set-keychain-settings -lut 21600 "$KEYCHAIN"
security unlock-keychain -p "$KP" "$KEYCHAIN"

if ! security import "$CERT" -k "$KEYCHAIN" -P "$P12_PASSWORD" -A -T /usr/bin/codesign -f pkcs12; then
    echo "::error::导入 p12 失败，通常是 SIGNING_CERT_PASSWORD 不对"
    rm -f "$CERT"
    exit 1
fi
rm -f "$CERT"
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KP" "$KEYCHAIN" >/dev/null

# codesign 只认搜索列表里的钥匙串，光传 --keychain 找不到身份（实测踩过）
security list-keychains -d user -s $(security list-keychains -d user | tr -d '"') "$KEYCHAIN"

# 自签根不被系统信任，find-identity 加 -v 会把它过滤掉，这里不加
echo "[import-cert] 可用签名身份："
security find-identity -p codesigning "$KEYCHAIN"

if [ -n "${GITHUB_ENV:-}" ]; then
    echo "SIGN_KEYCHAIN=$KEYCHAIN" >> "$GITHUB_ENV"
fi
