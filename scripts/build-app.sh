#!/bin/bash
# 编译并组装 MyWindowPip.app（通用二进制 x86_64 + arm64），
# 用 swiftc 直接编译，兼容仅装 Command Line Tools 的机器。
#
# 用法:
#   bash scripts/build-app.sh              # 输出 build/MyWindowPip.app
#   bash scripts/build-app.sh --debug      # 带 DEBUG 日志的构建
#   bash scripts/build-app.sh --install    # 构建后安装到 /Applications（路径稳定，减少反复授权）
#   bash scripts/build-app.sh --fast       # 只编当前架构，开发期加速
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="MyWindowPip"
EXEC="my-window-pip"
APP="build/$APP_NAME.app"
DEPLOY="14.0"
VERSION="$(tr -d '[:space:]' < VERSION)"

# 注意：macOS 自带 bash 3.2，配合 set -u 时空数组展开会报错，故用字符串保存可选参数
DEBUG_FLAGS=""
INSTALL=0
ARCHS=(x86_64 arm64)
OPT="-O"

for arg in "$@"; do
    case "$arg" in
        --debug)   DEBUG_FLAGS="-D DEBUG -g"; OPT="-Onone" ;;
        --install) INSTALL=1 ;;
        --fast)    ARCHS=("$(uname -m)") ;;
        *) echo "[build-app] 未知参数: $arg"; exit 1 ;;
    esac
done

FRAMEWORKS=(
    -framework AppKit
    -framework ScreenCaptureKit
    -framework AVFoundation
    -framework CoreMedia
    -framework CoreVideo
    -framework CoreImage
    -framework CoreGraphics
    -framework Carbon
)

echo "[build-app] 编译 $EXEC v$VERSION (${ARCHS[*]}) ..."
rm -rf "$APP" build/obj
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" build/obj

SLICES=()
for arch in "${ARCHS[@]}"; do
    echo "[build-app]   - 构建 $arch ..."
    swiftc $OPT $DEBUG_FLAGS -target "${arch}-apple-macos${DEPLOY}" \
        -o "build/obj/${EXEC}-${arch}" Sources/"$EXEC"/*.swift \
        "${FRAMEWORKS[@]}"
    SLICES+=("build/obj/${EXEC}-${arch}")
done

if [ "${#SLICES[@]}" -gt 1 ]; then
    lipo -create "${SLICES[@]}" -output "$APP/Contents/MacOS/$EXEC"
else
    cp "${SLICES[0]}" "$APP/Contents/MacOS/$EXEC"
fi
echo "[build-app] 架构: $(lipo -archs "$APP/Contents/MacOS/$EXEC")"

cp Resources/Info.plist "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist" >/dev/null

# 生成应用图标：由 Resources/AppIcon.png (1024) 生成多尺寸 AppIcon.icns
if [ -f Resources/AppIcon.png ]; then
    echo "[build-app] 生成 AppIcon.icns ..."
    ICONSET="$(mktemp -d)/AppIcon.iconset"
    mkdir -p "$ICONSET"
    sips -z 16 16     Resources/AppIcon.png --out "$ICONSET/icon_16x16.png"      >/dev/null
    sips -z 32 32     Resources/AppIcon.png --out "$ICONSET/icon_16x16@2x.png"   >/dev/null
    sips -z 32 32     Resources/AppIcon.png --out "$ICONSET/icon_32x32.png"      >/dev/null
    sips -z 64 64     Resources/AppIcon.png --out "$ICONSET/icon_32x32@2x.png"   >/dev/null
    sips -z 128 128   Resources/AppIcon.png --out "$ICONSET/icon_128x128.png"    >/dev/null
    sips -z 256 256   Resources/AppIcon.png --out "$ICONSET/icon_128x128@2x.png" >/dev/null
    sips -z 256 256   Resources/AppIcon.png --out "$ICONSET/icon_256x256.png"    >/dev/null
    sips -z 512 512   Resources/AppIcon.png --out "$ICONSET/icon_256x256@2x.png" >/dev/null
    sips -z 512 512   Resources/AppIcon.png --out "$ICONSET/icon_512x512.png"    >/dev/null
    cp Resources/AppIcon.png "$ICONSET/icon_512x512@2x.png"
    iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
fi

/usr/bin/codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || \
    echo "[build-app] 警告：ad-hoc 签名失败，App 仍可运行"

echo "[build-app] 已生成 $APP"

if [ "$INSTALL" = "1" ]; then
    echo "[build-app] 安装到 /Applications ..."
    pkill -x "$APP_NAME" 2>/dev/null || true
    rm -rf "/Applications/$APP_NAME.app"
    cp -R "$APP" "/Applications/$APP_NAME.app"
    echo "[build-app] 已安装 /Applications/$APP_NAME.app"
fi
