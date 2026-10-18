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
        // 最小化后再从菜单栏打开设置：先从程序坞还原。
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        window.orderFrontRegardless()
        // 从状态栏菜单触发时菜单仍在收起，推迟到菜单收起后再激活，并用 orderFrontRegardless
        // 保证窗口位于所有应用之上。激活与启动器一致用 activate(ignoringOtherApps:)：macOS 14 起
        // 协作式的 activate() 在用户正使用其他应用时可能被拒绝，窗口虽在最前，键盘焦点仍留在原应用。
        DispatchQueue.main.async {
            // 窗口已在此期间关闭（如紧接着调用了 close()）时不再重新展示。
            guard window.isVisible else { return }
            NSApp.activate(ignoringOtherApps: true)
            window.orderFrontRegardless()
            window.makeKey()
        }
    }

    func close() {
        window?.close()
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        // 可最小化、拉大与全屏（同 Raycast）；拉大时侧边栏宽度不变，右侧设置页随之加宽。
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.title = "OI 设置"
        // 侧边栏延伸到标题栏下方，红绿灯叠在侧边栏上（同系统设置）；标题只用于窗口菜单与调度中心，不显示。
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        let controller = NSHostingController(rootView: SettingsView(viewModel: viewModel))
        // 只按 SwiftUI 的最小尺寸约束窗口，不跟随理想尺寸：跟随时用户拉大的窗口会被弹回，
        // 内容理想高度超出屏幕时还会反复压回撑大、陷入约束更新死循环。
        controller.sizingOptions = [.minSize]
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
