import AppKit
import SwiftUI

/// 设置窗口的 AppKit 壳。菜单栏应用没有 app menu，设置入口在状态栏右键菜单，
/// 这里用固定单实例窗口托管 SwiftUI 表单，避免依赖 showSettingsWindow: 选择器。
@MainActor
final class SettingsWindowController {
    private let viewModel: SettingsViewModel
    private var window: NSWindow?

    init(viewModel: SettingsViewModel) {
        self.viewModel = viewModel
    }

    func show() {
        // 窗口关闭后实例常驻内存（isReleasedWhenClosed = false），重新展示时 SwiftUI 的
        // onAppear 未必重新触发，必须在展示入口主动同步系统登录项状态。
        viewModel.refreshLaunchAtLoginStatus()
        viewModel.reloadQuickAIAPIKey()
        let window = self.window ?? makeWindow()
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func close() {
        window?.close()
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 320),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "OI 设置"
        window.isReleasedWhenClosed = false
        let controller = NSHostingController(rootView: SettingsView(viewModel: viewModel))
        controller.sizingOptions = [.preferredContentSize]
        window.contentViewController = controller
        window.center()
        return window
    }
}
