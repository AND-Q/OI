import AppKit
import SwiftUI

/// 设置窗口的 AppKit 壳。菜单栏应用没有 app menu，设置入口在状态栏右键菜单，
/// 这里用固定单实例窗口托管 SwiftUI 表单，避免依赖 showSettingsWindow: 选择器。
@MainActor
final class SettingsWindowController {
    /// 系统设置的 Bundle ID，沿用「系统偏好设置」时期的标识。
    private static let systemSettingsBundleIdentifier = "com.apple.systempreferences"
    /// 系统设置退出后稍等再回到最前面：前台交给下一个应用、它的窗口升到最前面，与退出通知的先后不确定。
    private static let returnDelay: Duration = .milliseconds(300)

    private let viewModel: SettingsViewModel
    private var window: NSWindow?
    private var commitObservers: [any NSObjectProtocol] = []
    private var permissionObserver: (any NSObjectProtocol)?
    private var closeObserver: (any NSObjectProtocol)?
    /// 从设置页跳转到系统设置后，等待系统设置退出。
    private var systemSettingsObserver: (any NSObjectProtocol)?
    private var returnTask: Task<Void, Never>?

    init(viewModel: SettingsViewModel) {
        self.viewModel = viewModel
        viewModel.willOpenSystemSettings = { [weak self] in
            self?.returnAfterSystemSettingsQuits()
        }
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
                self?.stopWaitingForSystemSettings()
            }
        }
        return window
    }

    /// 设置页跳转到系统设置后，等系统设置退出再把设置窗口带回最前面：系统设置退出后前台交给上一个
    /// 普通应用，它的窗口会盖住设置窗口，而 OI 没有程序坞图标、也不在 ⌘Tab 中，用户难以找回。
    /// 设置窗口关闭后不再等待；用户自行打开的系统设置不受影响。
    private func returnAfterSystemSettingsQuits() {
        guard systemSettingsObserver == nil else { return }
        systemSettingsObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let bundleIdentifier = application?.bundleIdentifier
            MainActor.assumeIsolated {
                guard bundleIdentifier == SettingsWindowController.systemSettingsBundleIdentifier else { return }
                self?.systemSettingsDidQuit()
            }
        }
    }

    private func systemSettingsDidQuit() {
        stopWaitingForSystemSettings()
        returnTask = Task { [weak self] in
            try? await Task.sleep(for: SettingsWindowController.returnDelay)
            // 等待期间窗口已关闭时任务被取消，不再重新打开。
            guard let self, !Task.isCancelled else { return }
            self.returnTask = nil
            self.show()
        }
    }

    private func stopWaitingForSystemSettings() {
        returnTask?.cancel()
        returnTask = nil
        if let systemSettingsObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(systemSettingsObserver)
            self.systemSettingsObserver = nil
        }
    }
}
