#!/bin/bash
#
# build.sh — 构建 Lyrascope.app 到 Dist/
#
# 用法：
#   ./scripts/build.sh            # Release
#   ./scripts/build.sh debug      # Debug
#

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

CONFIG="Release"
if [[ "${1:-}" == "debug" ]]; then
    CONFIG="Debug"
fi

APP_NAME="Lyrascope"
BUILD_DIR=".build/dd"
DIST_DIR="Dist"

echo "==> 清理旧产物"
# Finder 里复制出来的「Lyrascope 2.app」之类也一并清掉，避免误点旧版本
rm -rf "$DIST_DIR/$APP_NAME.app" "$DIST_DIR/$APP_NAME "[0-9]*.app "$DIST_DIR/.DS_Store"

echo "==> 重新生成图标"
if command -v swift >/dev/null 2>&1; then
    swift -module-cache-path ./.mcache scripts/make_icon.swift \
        Sources/Resources/Assets.xcassets/AppIcon.appiconset >/dev/null || \
        echo "    (图标生成失败，沿用现有位图)"
fi

echo "==> 构建 $CONFIG"
# -disable-sandbox：命令行构建时 Swift 宏插件需要起子进程，某些沙箱环境（含
# 终端里的 sandbox-exec）会拒绝，加这个参数只影响本次构建，不影响 Xcode 里点击 ⌘R。
xcodebuild \
    -project "$APP_NAME.xcodeproj" \
    -scheme "$APP_NAME" \
    -configuration "$CONFIG" \
    -derivedDataPath "$BUILD_DIR" \
    OTHER_SWIFT_FLAGS='$(inherited) -disable-sandbox' \
    build

APP_PATH="$BUILD_DIR/Build/Products/$CONFIG/$APP_NAME.app"
if [[ ! -d "$APP_PATH" ]]; then
    echo "构建产物不存在：$APP_PATH" >&2
    exit 1
fi

echo "==> 拷贝到 $DIST_DIR"
mkdir -p "$DIST_DIR"
ditto "$APP_PATH" "$DIST_DIR/$APP_NAME.app"

echo "==> ad-hoc 签名"
xattr -cr "$DIST_DIR/$APP_NAME.app" || true
# 用「基于 identifier 的固定指定要求」签名：
# 这样每次重新构建后，系统里已经授予的「屏幕与系统录音」权限仍然有效，
# 不需要用户每次重新勾选。（ad-hoc 签名的 cdhash 每次都会变，默认要求会失效。）
codesign --force --deep --sign - \
    --requirements '=designated => identifier "com.zhangzhouqi.Lyrascope"' \
    "$DIST_DIR/$APP_NAME.app"

echo
echo "完成：$ROOT/$DIST_DIR/$APP_NAME.app"
echo "打开：open \"$DIST_DIR/$APP_NAME.app\""
echo "自检：\"$DIST_DIR/$APP_NAME.app/Contents/MacOS/$APP_NAME\" --selftest"
