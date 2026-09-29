import Foundation

/// 开机自启动开关需要注意的用户可见状态。
enum LaunchAtLoginNotice: Equatable {
    /// 已注册但等待用户在系统设置中批准。
    case approvalPending
    /// 注册或移除失败，携带系统给出的原因。
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

    private let settingsStore: any AppSettingsStoring
    private let loginItemController: any LoginItemControlling

    init(
        settingsStore: any AppSettingsStoring,
        loginItemController: any LoginItemControlling
    ) {
        self.settingsStore = settingsStore
        self.loginItemController = loginItemController
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
