import Foundation

/// 开机自启动开关需要注意的用户可见状态。
enum LaunchAtLoginNotice: Equatable {
    /// 已注册但等待用户在系统设置中批准。
    case approvalPending
    /// 注册或移除失败，携带系统给出的原因。
    case failure(String)
}

/// 全局快捷键（呼出启动器、划词翻译、截图翻译）切换需要注意的用户可见状态。
enum LauncherShortcutNotice: Equatable {
    /// 新快捷键注册失败（如被其他应用占用），携带原因。
    case failure(String)
}

@MainActor
final class SettingsViewModel: ObservableObject {
    /// 持久化的应用设置；任何改动立即写回存储。
    @Published var settings: AppSettings {
        didSet {
            settingsStore.save(settings)
            if settings.isFileSearchEnabled, !oldValue.isFileSearchEnabled {
                fileSearchAccessRequester?()
            }
            if settings.isForceTouchTranslationEnabled != oldValue.isForceTouchTranslationEnabled {
                forceTouchTranslationActivator?(settings.isForceTouchTranslationEnabled)
            }
        }
    }
    /// 开机自启动的开关状态来自系统登录项，而非持久化存储。
    @Published private(set) var isLaunchAtLoginEnabled: Bool
    @Published private(set) var launchAtLoginNotice: LaunchAtLoginNotice?
    @Published private(set) var launcherShortcutNotice: LauncherShortcutNotice?
    @Published private(set) var translatorShortcutNotice: LauncherShortcutNotice?
    @Published private(set) var screenTranslatorShortcutNotice: LauncherShortcutNotice?
    /// Quick AI API Key 存于独立的密钥存储，设置窗口展示时才读取，不在启动期访问钥匙串。
    @Published private(set) var quickAIAPIKey = ""
    /// 划词翻译的 API Key，与 Quick AI 的分开存放，读取时机同上。
    @Published private(set) var translationAPIKey = ""
    /// 辅助功能权限由系统持有，设置窗口展示或重新获得焦点时刷新（用户可能刚在系统设置中授权）。
    @Published private(set) var isAccessibilityTrusted: Bool
    /// 截图翻译所需的屏幕录制权限，刷新时机同上。
    @Published private(set) var isScreenCaptureTrusted: Bool

    /// Quick AI 接口地址经 http 访问公网主机时为 true，设置面板据此在地址栏下方提示明文传输。
    var isQuickAIBaseURLPlaintext: Bool {
        QuickAIConfiguration.isPlaintextOverPublicNetwork(baseURLString: settings.quickAIBaseURL)
    }

    /// 划词翻译接口地址的明文提示，规则同上。
    var isTranslationBaseURLPlaintext: Bool {
        QuickAIConfiguration.isPlaintextOverPublicNetwork(baseURLString: settings.translationBaseURL)
    }

    /// 由 AppCoordinator 注入：把呼出快捷键切换为给定组合并接管按键处理，
    /// 注册失败时抛错，不产生部分生效的状态。
    var launcherShortcutActivator: ((LauncherShortcut) throws -> Void)?
    /// 由 AppCoordinator 注入：翻译快捷键的激活闭包，约定同上。
    var translatorShortcutActivator: ((LauncherShortcut) throws -> Void)?
    /// 由 AppCoordinator 注入：截图翻译快捷键的激活闭包，约定同上。
    var screenTranslatorShortcutActivator: ((LauncherShortcut) throws -> Void)?
    /// 由 AppCoordinator 注入：文件搜索从关闭切到开启时请求桌面、文稿、下载目录授权。
    var fileSearchAccessRequester: (() -> Void)?
    /// 由 AppCoordinator 注入：用力点按取词开关变化时启动（true）或停止（false）全局监听。
    var forceTouchTranslationActivator: ((Bool) -> Void)?

    private let settingsStore: any AppSettingsStoring
    private let loginItemController: any LoginItemControlling
    private let quickAIKeyStore: any QuickAIKeyStoring
    private let translatorKeyStore: any QuickAIKeyStoring
    private let translatorEnvironment: any TranslatorEnvironmentHandling
    private var savedQuickAIAPIKey = ""
    private var savedTranslationAPIKey = ""

    init(
        settingsStore: any AppSettingsStoring,
        loginItemController: any LoginItemControlling,
        quickAIKeyStore: any QuickAIKeyStoring = MemoryQuickAIKeyStore(),
        translatorKeyStore: any QuickAIKeyStoring = MemoryQuickAIKeyStore(),
        translatorEnvironment: any TranslatorEnvironmentHandling = MemoryTranslatorEnvironment()
    ) {
        self.settingsStore = settingsStore
        self.loginItemController = loginItemController
        self.quickAIKeyStore = quickAIKeyStore
        self.translatorKeyStore = translatorKeyStore
        self.translatorEnvironment = translatorEnvironment
        self.settings = settingsStore.load()
        let status = loginItemController.status
        self.isLaunchAtLoginEnabled = status != .notRegistered
        self.launchAtLoginNotice = status == .requiresApproval ? .approvalPending : nil
        self.isAccessibilityTrusted = translatorEnvironment.isAccessibilityTrusted
        self.isScreenCaptureTrusted = translatorEnvironment.isScreenCaptureTrusted
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

    /// 应用新的呼出快捷键，规则见 `applyShortcut(_:to:)`。
    func applyLauncherShortcut(_ shortcut: LauncherShortcut) {
        applyShortcut(shortcut, to: .launcher)
    }

    /// 应用新的翻译快捷键，规则见 `applyShortcut(_:to:)`。
    func applyTranslatorShortcut(_ shortcut: LauncherShortcut) {
        applyShortcut(shortcut, to: .translator)
    }

    /// 应用新的截图翻译快捷键，规则见 `applyShortcut(_:to:)`。
    func applyScreenTranslatorShortcut(_ shortcut: LauncherShortcut) {
        applyShortcut(shortcut, to: .screenTranslator)
    }

    /// 设置翻译目标语言。选成与「原文已是目标语言时译为」相同的语言时两者互换：
    /// 两者相同会让已是目标语言的原文被「翻译」成同一种语言。
    func setTranslationTargetLanguage(_ language: TranslationLanguage) {
        var updated = settings
        if language == updated.translationAlternateLanguage {
            updated.translationAlternateLanguage = updated.translationTargetLanguage
        }
        updated.translationTargetLanguage = language
        settings = updated
    }

    /// 设置「原文已是目标语言时译为」，选成与目标语言相同时两者互换，规则同上。
    func setTranslationAlternateLanguage(_ language: TranslationLanguage) {
        var updated = settings
        if language == updated.translationTargetLanguage {
            updated.translationTargetLanguage = updated.translationAlternateLanguage
        }
        updated.translationAlternateLanguage = language
        settings = updated
    }

    /// 由 App 层在启动期注册失败时同步状态（如组合被其他应用占用），
    /// 让设置面板能看到失败原因，而不是平静地展示一个实际无效的快捷键。
    func reportShortcutRegistrationFailure(_ error: Error) {
        let reason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        launcherShortcutNotice = .failure(reason)
    }

    /// 翻译快捷键启动期注册失败时同步状态，约定同上。
    func reportTranslatorShortcutRegistrationFailure(_ error: Error) {
        let reason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        translatorShortcutNotice = .failure(reason)
    }

    /// 截图翻译快捷键启动期注册失败时同步状态，约定同上。
    func reportScreenTranslatorShortcutRegistrationFailure(_ error: Error) {
        let reason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        screenTranslatorShortcutNotice = .failure(reason)
    }

    func refreshPermissionStatus() {
        isAccessibilityTrusted = translatorEnvironment.isAccessibilityTrusted
        isScreenCaptureTrusted = translatorEnvironment.isScreenCaptureTrusted
    }

    func requestAccessibilityAccess() {
        translatorEnvironment.requestAccessibilityAccess()
    }

    func requestScreenCaptureAccess() {
        translatorEnvironment.requestScreenCaptureAccess()
    }

    func openTrackpadSettings() {
        translatorEnvironment.openTrackpadSettings()
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

    /// 划词翻译 API Key 的输入，保存时机同 Quick AI，见 `commitTranslationAPIKey()`。
    func setTranslationAPIKey(_ apiKey: String) {
        translationAPIKey = apiKey
    }

    func commitTranslationAPIKey() {
        let trimmed = translationAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != savedTranslationAPIKey else { return }
        translatorKeyStore.save(trimmed)
        savedTranslationAPIKey = trimmed
    }

    func reloadTranslationAPIKey() {
        translationAPIKey = translatorKeyStore.load() ?? ""
        savedTranslationAPIKey = translationAPIKey
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

    /// 三个全局快捷键：各自有设置值、提示与激活闭包，组合互不相同。
    private enum ShortcutTarget: CaseIterable {
        case launcher
        case translator
        case screenTranslator

        var setting: WritableKeyPath<AppSettings, LauncherShortcut> {
            switch self {
            case .launcher: \.launcherShortcut
            case .translator: \.translatorShortcut
            case .screenTranslator: \.screenTranslatorShortcut
            }
        }

        var name: String {
            switch self {
            case .launcher: "呼出"
            case .translator: "翻译"
            case .screenTranslator: "截图翻译"
            }
        }
    }

    /// 应用新的全局快捷键：先试注册，成功才持久化；失败时回滚注册到原快捷键并提示原因，
    /// 保证原快捷键始终可用。与其他快捷键相同的组合直接拒绝，不尝试注册。
    /// 重申当前快捷键（冲突后按原键确认、重试默认键）仍执行激活——
    /// 既是重试入口也能自愈回滚失败的场景，仅在无失败提示可清理时跳过。
    private func applyShortcut(_ shortcut: LauncherShortcut, to target: ShortcutTarget) {
        if let problem = shortcut.problem {
            setNotice(.failure(ShortcutFormatter.description(of: problem)), for: target)
            return
        }
        if let other = ShortcutTarget.allCases.first(where: { $0 != target && settings[keyPath: $0.setting] == shortcut }) {
            setNotice(.failure("与\(other.name)快捷键相同，请换一个组合"), for: target)
            return
        }
        if shortcut == settings[keyPath: target.setting], notice(for: target) == nil {
            return
        }
        guard let activator = activator(for: target) else { return }
        do {
            try activator(shortcut)
            settings[keyPath: target.setting] = shortcut
            setNotice(nil, for: target)
        } catch {
            // 注册服务在尝试注册前会先注销旧热键，任何失败路径此刻都处于零热键状态，
            // 全靠回滚恢复；回滚也失败（如原组合在间隙被抢占）时必须告知严重后果。
            let reason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            do {
                try activator(settings[keyPath: target.setting])
                setNotice(.failure(reason), for: target)
            } catch {
                setNotice(
                    .failure(
                        "原快捷键重新注册也失败，当前没有可用的\(target.name)快捷键（新组合原因：\(reason)）。请重新录制组合或重启 OI"
                    ),
                    for: target
                )
            }
        }
    }

    private func activator(for target: ShortcutTarget) -> ((LauncherShortcut) throws -> Void)? {
        switch target {
        case .launcher: launcherShortcutActivator
        case .translator: translatorShortcutActivator
        case .screenTranslator: screenTranslatorShortcutActivator
        }
    }

    private func notice(for target: ShortcutTarget) -> LauncherShortcutNotice? {
        switch target {
        case .launcher: launcherShortcutNotice
        case .translator: translatorShortcutNotice
        case .screenTranslator: screenTranslatorShortcutNotice
        }
    }

    private func setNotice(_ notice: LauncherShortcutNotice?, for target: ShortcutTarget) {
        switch target {
        case .launcher: launcherShortcutNotice = notice
        case .translator: translatorShortcutNotice = notice
        case .screenTranslator: screenTranslatorShortcutNotice = notice
        }
    }
}
