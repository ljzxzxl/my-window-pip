#!/bin/bash
# 把 build/MyWindowPip.app 打包成 dist/MyWindowPip-<版本>.dmg 并生成 SHA256。
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="MyWindowPip"
VERSION="$(tr -d '[:space:]' < VERSION)"
APP="build/$APP_NAME.app"
DIST="dist"
DMG="$DIST/${APP_NAME}-${VERSION}.dmg"

[ -d "$APP" ] || { echo "请先运行 scripts/build-app.sh"; exit 1; }

mkdir -p "$DIST"
rm -f "$DMG" "$DMG.sha256"

STAGING="$(mktemp -d)"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGING" -ov -format UDZO "$DMG"
rm -rf "$STAGING"

shasum -a 256 "$DMG" | tee "$DMG.sha256"
echo "[make-dmg] 已生成 $DMG"
