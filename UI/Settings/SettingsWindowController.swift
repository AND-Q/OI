import AppKit
import SwiftUI

/// 设置窗口的 AppKit 壳。设置入口在状态栏右键菜单（窗口打开期间应用菜单中的「设置…」也指向这里），
/// 这里用固定单实例窗口托管 SwiftUI 表单，避免依赖 showSettingsWindow: 选择器。
/// 窗口打开期间 OI 作为普通应用（程序坞显示图标、可用 ⌘Tab 切回），关闭后恢复为菜单栏应用：
/// 菜单栏应用不在程序坞与 ⌘Tab 中，窗口被其他应用盖住后无从切回，前台应用（如系统设置）退出时
/// 系统也不会把前台交还给它。
@MainActor
final class SettingsWindowController {
    private let viewModel: SettingsViewModel
    /// 切换 OI 的激活策略；测试替换为记录，避免测试宿主的程序坞图标反复出现。
    private let setActivationPolicy: @MainActor (NSApplication.ActivationPolicy) -> Void
    private var window: NSWindow?
    private var commitObservers: [any NSObjectProtocol] = []
    private var permissionObserver: (any NSObjectProtocol)?
    private var closeObserver: (any NSObjectProtocol)?

    init(
        viewModel: SettingsViewModel,
        setActivationPolicy: @escaping @MainActor (NSApplication.ActivationPolicy) -> Void = {
            _ = NSApp.setActivationPolicy($0)
        }
    ) {
        self.viewModel = viewModel
        self.setActivationPolicy = setActivationPolicy
    }

    func show() {
        // 窗口关闭后实例常驻内存（isReleasedWhenClosed = false），重新展示时 SwiftUI 的
        // onAppear 未必重新触发，必须在展示入口主动同步系统登录项状态。
        viewModel.refreshLaunchAtLoginStatus()
        viewModel.refreshPermissionStatus()
        viewModel.reloadQuickAIAPIKey()
        viewModel.reloadTranslationAPIKey()
        let window = self.window ?? makeWindow()
        self.window = window
        setActivationPolicy(.regular)
        window.orderFrontRegardless()
        // macOS 14 起激活是协作式的：从状态栏菜单触发时菜单仍在收起，此时请求激活常被拒绝，
        // 窗口只会排在本应用内最前、被其他应用压住。推迟到菜单收起后再激活，
        // 并用 orderFrontRegardless 保证激活未获批准时窗口也位于所有应用之上。
        DispatchQueue.main.async {
            // 窗口已在此期间关闭（如紧接着调用了 close()）时不再重新展示。
            guard window.isVisible else { return }
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
        // 输入框失焦不覆盖所有离开方式：直接点关闭按钮，或不点别处就按快捷键切到启动器
        // （窗口失去 key 时 SwiftUI 输入框并不失焦），这两种情况都补一次保存。
        commitObservers = [NSWindow.willCloseNotification, NSWindow.didResignKeyNotification].map { name in
            NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.viewModel.commitQuickAIAPIKey()
                    self?.viewModel.commitTranslationAPIKey()
                }
            }
        }
        // 从系统设置授权辅助功能后回到设置窗口，权限状态随之更新。
        permissionObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.viewModel.refreshPermissionStatus()
            }
        }
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.setActivationPolicy(.accessory)
            }
        }
        return window
    }
}
