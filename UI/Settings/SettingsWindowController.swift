import AppKit
import SwiftUI

/// 设置窗口的 AppKit 壳。菜单栏应用没有 app menu，设置入口在状态栏右键菜单，
/// 这里用固定单实例窗口托管 SwiftUI 表单，避免依赖 showSettingsWindow: 选择器。
@MainActor
final class SettingsWindowController {
    private let viewModel: SettingsViewModel
    private var window: NSWindow?
    private var closeObserver: (any NSObjectProtocol)?

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
        // macOS 14 起激活是协作式的：从状态栏菜单触发时菜单仍在收起，此时请求激活常被拒绝，
        // 窗口只会排在本应用内最前、被其他应用压住。推迟到菜单收起后再激活，
        // 并用 orderFrontRegardless 保证激活未获批准时窗口也位于所有应用之上。
        DispatchQueue.main.async {
            NSApp.activate()
            window.orderFrontRegardless()
            window.makeKey()
        }
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
        // 输入 API Key 后直接点关闭按钮时输入框未必先失焦，关闭前补一次保存。
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.viewModel.commitQuickAIAPIKey()
            }
        }
        return window
    }
}
