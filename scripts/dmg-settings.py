# dmgbuild 的配置，由 scripts/make-dmg.sh 调用，并通过 -D 传入 app（OI.app 路径）与 background（背景图）。
# 窗口布局直接写进磁盘映像的 .DS_Store，不经过访达。
import os.path

app = defines["app"]
app_name = os.path.basename(app)
volume_icon = os.path.join(app, "Contents", "Resources", "AppIcon.icns")

format = "UDZO"
filesystem = "HFS+"
files = [app]
symlinks = {"Applications": "/Applications"}
# 安装窗口里显示为「OI」；访达开着「显示所有文件扩展名」时仍显示 .app
hide_extension = [app_name]
icon = volume_icon if os.path.exists(volume_icon) else None
background = defines["background"]

# 窗口宽 600、高 432（含标题栏），内容区约 600×400；背景图 600×440 留出余量，不露白边
window_rect = ((200, 120), (600, 432))
default_view = "icon-view"
show_toolbar = False
show_status_bar = False
show_pathbar = False
show_sidebar = False
show_tab_view = False
show_icon_preview = False
arrange_by = None
icon_size = 128
text_size = 13
label_pos = "bottom"
# 图标中心，与背景图中箭头两端对齐：OI 在左，「应用程序」在右
icon_locations = {
    app_name: (150, 180),
    "Applications": (450, 180),
}
