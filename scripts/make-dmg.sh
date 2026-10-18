#!/bin/bash
# 把 OI.app 打包为带安装界面的 dmg：窗口中 OI 在左、「应用程序」快捷方式在右，背景箭头提示拖过去安装。
# 用法：scripts/make-dmg.sh <OI.app 路径> <版本号> <输出的 dmg 路径>
# 窗口布局由「访达」写入磁盘映像，第一次运行时系统会询问是否允许终端控制「访达」，需要允许。
set -euo pipefail

if [[ $# -ne 3 ]]; then
    echo "用法：scripts/make-dmg.sh <OI.app 路径> <版本号> <输出的 dmg 路径>" >&2
    exit 1
fi

ROOT=$(cd "$(dirname "$0")/.." && pwd)
APP=$1
VERSION=$2
DMG=$3
VOLUME="OI $VERSION"
MOUNT="/Volumes/$VOLUME"
WORK=$(mktemp -d)
STAGING="$WORK/staging"
RW_DMG="$WORK/rw.dmg"
DEVICE=""
# 中途出错时推出已挂载的临时映像
trap '[[ -n "$DEVICE" ]] && hdiutil detach -quiet -force "$DEVICE"; rm -rf "$WORK"' EXIT

# 同名磁盘映像已挂载时，访达无法区分要布置的是哪一个
if [[ -d "$MOUNT" ]]; then
    echo "请先推出已挂载的「${VOLUME}」磁盘映像。" >&2
    exit 1
fi

# 内容：OI.app、「应用程序」快捷方式，以及隐藏的背景图与磁盘图标；用 ditto 复制，保留签名与扩展属性
mkdir -p "$STAGING/.background"
ditto "$APP" "$STAGING/OI.app"
ln -s /Applications "$STAGING/Applications"
# 合并普通屏与 Retina 两种尺寸的背景图
tiffutil -cathidpicheck "$ROOT/assets/dmg-background.png" "$ROOT/assets/dmg-background@2x.png" \
    -out "$STAGING/.background/background.tiff" >/dev/null 2>&1
if [[ -f "$APP/Contents/Resources/AppIcon.icns" ]]; then
    cp "$APP/Contents/Resources/AppIcon.icns" "$STAGING/.VolumeIcon.icns"
fi

# 先做可写的磁盘映像，挂载后由访达布置窗口，最后转成压缩的只读映像
SIZE_MB=$(( $(du -sm "$STAGING" | cut -f1) + 20 ))
hdiutil create -quiet -volname "$VOLUME" -srcfolder "$STAGING" -fs HFS+ -format UDRW -size "${SIZE_MB}m" "$RW_DMG"
DEVICE=$(hdiutil attach -readwrite -noverify -noautoopen "$RW_DMG" | awk '/Apple_HFS/ { print $1 }')

if [[ -f "$MOUNT/.VolumeIcon.icns" ]] && xcrun --find SetFile >/dev/null 2>&1; then
    xcrun SetFile -a C "$MOUNT"
fi

# 窗口宽 600、高 432（含标题栏），内容区约 600×400；背景图 600×440 留出余量，不露白边。
# 图标位置是图标中心，与背景图中箭头两端对齐。关闭后重新打开并微调一次窗口大小，促使访达保存布局
osascript <<EOF
tell application "Finder"
    tell disk "$VOLUME"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set bounds of container window to {200, 120, 800, 552}
        set viewOptions to icon view options of container window
        set arrangement of viewOptions to not arranged
        set icon size of viewOptions to 128
        set text size of viewOptions to 13
        set background picture of viewOptions to file ".background:background.tiff"
        set position of item "OI.app" of container window to {150, 180}
        set position of item "Applications" of container window to {450, 180}
        close
        open
        update without registering applications
        delay 1
        set bounds of container window to {200, 120, 790, 542}
        delay 1
        set bounds of container window to {200, 120, 800, 552}
        delay 1
        close
    end tell
end tell
EOF

# 访达在关闭窗口后才把视图选项与图标位置异步写进 .DS_Store（标记分别为 icvp、Iloc），
# 打开窗口时先写入的只有窗口大小；两者都写入后再推出，最多等 30 秒
for _ in $(seq 30); do
    if [[ -f "$MOUNT/.DS_Store" ]] && grep -aq icvp "$MOUNT/.DS_Store" && grep -aq Iloc "$MOUNT/.DS_Store"; then
        break
    fi
    sleep 1
done
if ! { grep -aq icvp "$MOUNT/.DS_Store" && grep -aq Iloc "$MOUNT/.DS_Store"; } 2>/dev/null; then
    echo "访达没有写入窗口布局，请确认已允许终端控制「访达」后重试。" >&2
    exit 1
fi
sleep 2
sync
for _ in 1 2 3 4 5; do
    hdiutil detach -quiet "$DEVICE" && DEVICE="" && break
    sleep 2
done

rm -f "$DMG"
hdiutil convert -quiet "$RW_DMG" -format UDZO -imagekey zlib-level=9 -o "$DMG"
