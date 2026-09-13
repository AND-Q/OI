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
    }
}
