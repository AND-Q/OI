#!/bin/bash
# 把 OI.app 打包为带安装界面的 dmg：窗口中 OI 在左、「应用程序」快捷方式在右，背景箭头提示拖过去安装。
# 用 dmgbuild 直接把窗口布局写进磁盘映像（配置见 scripts/dmg-settings.py），不经过访达，每次结果一致。
# 用法：scripts/make-dmg.sh <OI.app 路径> <版本号> <输出的 dmg 路径>
# 依赖：pip3 install dmgbuild
set -euo pipefail

if [[ $# -ne 3 ]]; then
    echo "用法：scripts/make-dmg.sh <OI.app 路径> <版本号> <输出的 dmg 路径>" >&2
    exit 1
fi
if ! command -v dmgbuild >/dev/null 2>&1; then
    echo "缺少 dmgbuild，请先执行：pip3 install dmgbuild" >&2
    exit 1
fi

ROOT=$(cd "$(dirname "$0")/.." && pwd)
APP=$1
VERSION=$2
DMG=$3
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# 合并普通屏与 Retina 两种尺寸的背景图
tiffutil -cathidpicheck "$ROOT/assets/dmg-background.png" "$ROOT/assets/dmg-background@2x.png" \
    -out "$WORK/background.tiff" >/dev/null 2>&1

rm -f "$DMG"
dmgbuild -s "$ROOT/scripts/dmg-settings.py" -D app="$APP" -D background="$WORK/background.tiff" "OI $VERSION" "$DMG"
