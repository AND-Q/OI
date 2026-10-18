import SwiftUI

@main
struct OIApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    // 菜单栏进程通过 AppCoordinator 持有其自定义 NSPanel。
    // Settings 场景用于保持 SwiftUI App 生命周期有效，且不会创建窗口。
    var body: some Scene {
        Settings {
            EmptyView()
        }
        .commands {
            // 设置窗口打开期间 OI 作为普通应用显示应用菜单，其中的「设置…」默认打开上面的空场景，
            // 改为打开自有的设置窗口。
            CommandGroup(replacing: .appSettings) {
                Button("设置…") {
                    appDelegate.showSettings()
                }
                .keyboardShortcut(",")
            }
        }
    }
}
