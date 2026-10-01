import Foundation

/// 开机自启动开关需要注意的用户可见状态。
enum LaunchAtLoginNotice: Equatable {
    /// 已注册但等待用户在系统设置中批准。
    case approvalPending
    /// 注册或移除失败，携带系统给出的原因。
    case failure(String)
}

/// 呼出快捷键切换需要注意的用户可见状态。
enum LauncherShortcutNotice: Equatable {
    /// 新快捷键注册失败（如被其他应用占用），携带原因。
    case failure(String)
}

@MainActor
final class SettingsViewModel: ObservableObject {
    /// 持久化的应用设置；任何改动立即写回存储。
    @Published var settings: AppSettings {
        didSet { settingsStore.save(settings) }
    }
    /// 开机自启动的开关状态来自系统登录项，而非持久化存储。
    @Published private(set) var isLaunchAtLoginEnabled: Bool
    @Published private(set) var launchAtLoginNotice: LaunchAtLoginNotice?
    @Published private(set) var launcherShortcutNotice: LauncherShortcutNotice?
    /// Quick AI API Key 存于独立的密钥存储，设置窗口展示时才读取，不在启动期访问钥匙串。
    @Published private(set) var quickAIAPIKey = ""

    /// 由 AppCoordinator 注入：把呼出快捷键切换为给定组合并接管按键处理，
    /// 注册失败时抛错，不产生部分生效的状态。
    var launcherShortcutActivator: ((LauncherShortcut) throws -> Void)?

    private let settingsStore: any AppSettingsStoring
    private let loginItemController: any LoginItemControlling
    private let quickAIKeyStore: any QuickAIKeyStoring
    private var savedQuickAIAPIKey = ""

    init(
        settingsStore: any AppSettingsStoring,
        loginItemController: any LoginItemControlling,
        quickAIKeyStore: any QuickAIKeyStoring = MemoryQuickAIKeyStore()
    ) {
        self.settingsStore = settingsStore
        self.loginItemController = loginItemController
        self.quickAIKeyStore = quickAIKeyStore
        self.settings = settingsStore.load()
        let status = loginItemController.status
        self.isLaunchAtLoginEnabled = status != .notRegistered
        self.launchAtLoginNotice = status == .requiresApproval ? .approvalPending : nil
    }

    /// 注册或移除登录项。失败时回读系统真实状态并给出失败提示，
    /// 注册后系统要求批准时给出引导提示。
    func setLaunchAtLogin(_ enabled: Bool) {
        guard (loginItemController.status != .notRegistered) != enabled else { return }
        do {
            if enabled {
                try loginItemController.register()
            } else {
                try loginItemController.unregister()
            }
        } catch {
            let reason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            launchAtLoginNotice = .failure(reason)
            isLaunchAtLoginEnabled = loginItemController.status != .notRegistered
            return
        }
        isLaunchAtLoginEnabled = enabled
        launchAtLoginNotice =
            enabled && loginItemController.status == .requiresApproval ? .approvalPending : nil
    }

    /// 应用新的呼出快捷键：先试注册，成功才持久化；
    /// 失败时回滚注册到原快捷键并提示原因，保证呼出热键始终可用。
    /// 重申当前快捷键（冲突后按原键确认、重试默认键）仍执行激活——
    /// 既是重试入口也能自愈回滚失败的场景，仅在无失败提示可清理时跳过。
    func applyLauncherShortcut(_ shortcut: LauncherShortcut) {
        guard shortcut.isValid else {
            launcherShortcutNotice = .failure("快捷键需包含 ⌘、⌥ 或 ⌃ 修饰键")
            return
        }
        if shortcut == settings.launcherShortcut, launcherShortcutNotice == nil {
            return
        }
        guard let activator = launcherShortcutActivator else { return }
        do {
            try activator(shortcut)
            settings.launcherShortcut = shortcut
            launcherShortcutNotice = nil
        } catch {
            // 注册服务在尝试注册前会先注销旧热键，任何失败路径此刻都处于零热键状态，
            // 全靠回滚恢复；回滚也失败（如原组合在间隙被抢占）时必须告知严重后果。
            let reason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            do {
                try activator(settings.launcherShortcut)
                launcherShortcutNotice = .failure(reason)
            } catch {
                launcherShortcutNotice = .failure(
                    "原快捷键重新注册也失败，当前没有可用的呼出快捷键（新组合原因：\(reason)）。请重新录制组合或重启 OI"
                )
            }
        }
    }

    /// 由 App 层在启动期注册失败时同步状态（如组合被其他应用占用），
    /// 让设置面板能看到失败原因，而不是平静地展示一个实际无效的快捷键。
    func reportShortcutRegistrationFailure(_ error: Error) {
        let reason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        launcherShortcutNotice = .failure(reason)
    }

    /// 输入过程只更新界面，不逐字写钥匙串；由 `commitQuickAIAPIKey()` 统一保存。
    func setQuickAIAPIKey(_ apiKey: String) {
        quickAIAPIKey = apiKey
    }

    /// 回车、离开输入框或关闭设置窗口时保存；与已保存的值相同则不写入。
    func commitQuickAIAPIKey() {
        let trimmed = quickAIAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != savedQuickAIAPIKey else { return }
        quickAIKeyStore.save(trimmed)
        savedQuickAIAPIKey = trimmed
    }

    /// 设置窗口展示时读取已保存的 API Key。
    func reloadQuickAIAPIKey() {
        quickAIAPIKey = quickAIKeyStore.load() ?? ""
        savedQuickAIAPIKey = quickAIAPIKey
    }

    /// 设置窗口打开时同步系统真实状态：用户可能直接在系统设置中批准或移除了登录项。
    func refreshLaunchAtLoginStatus() {
        let status = loginItemController.status
        isLaunchAtLoginEnabled = status != .notRegistered
        if status == .requiresApproval {
            launchAtLoginNotice = .approvalPending
        } else if launchAtLoginNotice == .approvalPending {
            launchAtLoginNotice = nil
        }
    }
}
