#!/bin/bash
# 编译 Release 版 OI，打包为 zip 并生成带校验值的发布说明，供上传到 GitHub Release。
# 用法：在已提交的干净工作区中执行 scripts/release.sh
set -euo pipefail

cd "$(dirname "$0")/.."

# 发布的安装包必须与某个提交一一对应
if [[ -n "$(git status --porcelain)" ]]; then
    echo "工作区有未提交的改动，请先提交后再发布。" >&2
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
ZIP="$BUILD_DIR/OI-$VERSION.zip"

echo "编译 OI ${VERSION}（Release）…"
xcodebuild -project OI.xcodeproj -scheme OI -configuration Release -derivedDataPath "$BUILD_DIR" -quiet clean build

codesign --verify --deep --strict "$APP"

# 用 ditto 打包，保留签名与扩展属性
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
SHA256=$(shasum -a 256 "$ZIP" | awk '{ print $1 }')

{
    cat "$NOTES"
    printf '\n---\n\n`OI-%s.zip` 的 SHA-256：`%s`\n' "$VERSION" "$SHA256"
} > "$BUILD_DIR/release-notes.md"

echo
echo "安装包：$ZIP"
echo "SHA-256：$SHA256"
echo
echo "确认无误后发布（标签指向当前提交）："
echo "  gh release create v$VERSION \"$ZIP\" --target $(git rev-parse HEAD) --title \"OI $VERSION\" --notes-file $BUILD_DIR/release-notes.md"
