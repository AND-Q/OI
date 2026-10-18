#!/bin/bash
# 编译 Release 版 OI，打包为 dmg 磁盘映像并生成带校验值的发布说明，供上传到 GitHub Release。
# 用法：在已提交的干净工作区中执行 scripts/release.sh
set -euo pipefail

cd "$(dirname "$0")/.."

# 发布的安装包必须与某个提交一一对应
if [[ -n "$(git status --porcelain)" ]]; then
    echo "工作区有未提交的改动，请先提交后再发布。" >&2
    exit 1
fi

# 制作安装包要用到 dmgbuild，编译前先检查，免得编译完才发现缺少
if ! command -v dmgbuild >/dev/null 2>&1; then
    echo "缺少 dmgbuild，请先执行：pip3 install dmgbuild" >&2
    exit 1
fi

VERSION=$(xcodebuild -project OI.xcodeproj -scheme OI -configuration Release -showBuildSettings \
    | awk -F' = ' '/^ *MARKETING_VERSION = / { print $2; exit }')
if [[ -z "$VERSION" ]]; then
    echo "读取版本号失败。" >&2
    exit 1
fi

NOTES="docs/releases/v$VERSION.md"
if [[ ! -f "$NOTES" ]]; then
    echo "缺少发布说明 ${NOTES}，请先编写。" >&2
    exit 1
fi

BUILD_DIR=build/release
APP="$BUILD_DIR/Build/Products/Release/OI.app"
DMG="$BUILD_DIR/OI-$VERSION.dmg"

echo "编译 OI ${VERSION}（Release）…"
xcodebuild -project OI.xcodeproj -scheme OI -configuration Release -derivedDataPath "$BUILD_DIR" -quiet clean build

codesign --verify --deep --strict "$APP"

echo "制作安装包…"
scripts/make-dmg.sh "$APP" "$VERSION" "$DMG"
SHA256=$(shasum -a 256 "$DMG" | awk '{ print $1 }')

{
    cat "$NOTES"
    printf '\n---\n\n`OI-%s.dmg` 的 SHA-256：`%s`\n' "$VERSION" "$SHA256"
} > "$BUILD_DIR/release-notes.md"

echo
echo "安装包：$DMG"
echo "SHA-256：$SHA256"
echo
echo "确认无误后发布（标签指向当前提交）："
echo "  gh release create v$VERSION \"$DMG\" --target $(git rev-parse HEAD) --title \"OI $VERSION\" --notes-file $BUILD_DIR/release-notes.md"
