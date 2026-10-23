import Foundation

/// 开机自启动开关需要注意的用户可见状态。
enum LaunchAtLoginNotice: Equatable {
    /// 已注册但等待用户在系统设置中批准。
    case approvalPending
    /// 注册或移除失败，携带系统给出的原因。
    case failure(String)
}

/// 全局快捷键（呼出启动器、划词翻译、截图翻译）切换需要注意的用户可见状态。
enum GlobalShortcutNotice: Equatable {
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
            // 改了接口地址，之前的连接结果与模型列表就不再对应当前的地址。
            for target in AIEndpointTarget.allCases
            where settings[keyPath: target.baseURL] != oldValue[keyPath: target.baseURL] {
                resetAIEndpointCheck(target)
            }
        }
    }
    /// 开机自启动的开关状态来自系统登录项，而非持久化存储。
    @Published private(set) var isLaunchAtLoginEnabled: Bool
    @Published private(set) var launchAtLoginNotice: LaunchAtLoginNotice?
    @Published private(set) var launcherShortcutNotice: GlobalShortcutNotice?
    @Published private(set) var translatorShortcutNotice: GlobalShortcutNotice?
    @Published private(set) var screenTranslatorShortcutNotice: GlobalShortcutNotice?
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
        AIEndpointConfiguration.isPlaintextOverPublicNetwork(baseURLString: settings.quickAIBaseURL)
    }

    /// 划词翻译接口地址的明文提示，规则同上。
    var isTranslationBaseURLPlaintext: Bool {
        AIEndpointConfiguration.isPlaintextOverPublicNetwork(baseURLString: settings.translationBaseURL)
    }

    /// 由 AppCoordinator 注入：把呼出快捷键切换为给定组合并接管按键处理，
    /// 注册失败时抛错，不产生部分生效的状态。
    var launcherShortcutActivator: ((GlobalShortcut) throws -> Void)?
    /// 由 AppCoordinator 注入：翻译快捷键的激活闭包，约定同上。
    var translatorShortcutActivator: ((GlobalShortcut) throws -> Void)?
    /// 由 AppCoordinator 注入：截图翻译快捷键的激活闭包，约定同上。
    var screenTranslatorShortcutActivator: ((GlobalShortcut) throws -> Void)?
    /// 由 AppCoordinator 注入：文件搜索从关闭切到开启时请求桌面、文稿、下载目录授权。
    var fileSearchAccessRequester: (() -> Void)?
    /// 由 AppCoordinator 注入：用力点按取词开关变化时启动（true）或停止（false）全局监听。
    var forceTouchTranslationActivator: ((Bool) -> Void)?

    private let settingsStore: any AppSettingsStoring
    private let loginItemController: any LoginItemControlling
    private let quickAIKeyStore: any APIKeyStoring
    private let translatorKeyStore: any APIKeyStoring
    private let translatorEnvironment: any TranslatorEnvironmentHandling
    private let listAIModels: ListAIModels?
    private var savedQuickAIAPIKey = ""
    private var savedTranslationAPIKey = ""
    /// 「测试连接」与「获取模型」的结果；未检查或输入已改动时没有条目。
    @Published private var aiEndpointChecks: [AIEndpointTarget: AIEndpointCheck] = [:]
    private var aiEndpointCheckTasks: [AIEndpointTarget: Task<Void, Never>] = [:]
    private var aiEndpointCheckGenerations: [AIEndpointTarget: Int] = [:]

    init(
        settingsStore: any AppSettingsStoring,
        loginItemController: any LoginItemControlling,
        quickAIKeyStore: any APIKeyStoring = MemoryAPIKeyStore(),
        translatorKeyStore: any APIKeyStoring = MemoryAPIKeyStore(),
        translatorEnvironment: any TranslatorEnvironmentHandling = MemoryTranslatorEnvironment(),
        listAIModels: ListAIModels? = nil
    ) {
        self.settingsStore = settingsStore
        self.loginItemController = loginItemController
        self.quickAIKeyStore = quickAIKeyStore
        self.translatorKeyStore = translatorKeyStore
        self.translatorEnvironment = translatorEnvironment
        self.listAIModels = listAIModels
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
            launchAtLoginNotice = .failure(Self.reason(of: error))
            isLaunchAtLoginEnabled = loginItemController.status != .notRegistered
            return
        }
        isLaunchAtLoginEnabled = enabled
        launchAtLoginNotice =
            enabled && loginItemController.status == .requiresApproval ? .approvalPending : nil
    }

    /// 应用新的呼出快捷键，规则见 `applyShortcut(_:to:)`。
    func applyLauncherShortcut(_ shortcut: GlobalShortcut) {
        applyShortcut(shortcut, to: .launcher)
    }

    /// 应用新的翻译快捷键，规则见 `applyShortcut(_:to:)`。
    func applyTranslatorShortcut(_ shortcut: GlobalShortcut) {
        applyShortcut(shortcut, to: .translator)
    }

    /// 应用新的截图翻译快捷键，规则见 `applyShortcut(_:to:)`。
    func applyScreenTranslatorShortcut(_ shortcut: GlobalShortcut) {
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
    func reportShortcutRegistrationFailure(_ error: Error, for target: ShortcutTarget) {
        setNotice(.failure(Self.reason(of: error)), for: target)
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
        guard apiKey != quickAIAPIKey else { return }
        quickAIAPIKey = apiKey
        resetAIEndpointCheck(.quickAI)
    }

    /// 回车、离开输入框或关闭设置窗口时保存；与已保存的值相同则不写入。
    func commitQuickAIAPIKey() {
        commit(quickAIAPIKey, savedAs: &savedQuickAIAPIKey, to: quickAIKeyStore)
    }

    /// 设置窗口展示时读取已保存的 API Key。
    func reloadQuickAIAPIKey() {
        quickAIAPIKey = quickAIKeyStore.load() ?? ""
        savedQuickAIAPIKey = quickAIAPIKey
    }

    /// 划词翻译 API Key 的输入，保存时机同 Quick AI，见 `commitTranslationAPIKey()`。
    func setTranslationAPIKey(_ apiKey: String) {
        guard apiKey != translationAPIKey else { return }
        translationAPIKey = apiKey
        resetAIEndpointCheck(.translation)
    }

    func commitTranslationAPIKey() {
        commit(translationAPIKey, savedAs: &savedTranslationAPIKey, to: translatorKeyStore)
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

    /// 设置面板中的两组 AI 接口：Quick AI 与划词翻译各自填写地址、模型与 API Key。
    enum AIEndpointTarget: CaseIterable {
        case quickAI
        case translation

        var baseURL: KeyPath<AppSettings, String> {
            switch self {
            case .quickAI: \.quickAIBaseURL
            case .translation: \.translationBaseURL
            }
        }

        var model: WritableKeyPath<AppSettings, String> {
            switch self {
            case .quickAI: \.quickAIModel
            case .translation: \.translationModel
            }
        }
    }

    /// 「测试连接」的结果，供设置面板显示。
    enum AIEndpointStatus: Equatable {
        case checking
        /// 连接成功，填写的模型在列表中（或尚未填写模型）。
        case connected(modelCount: Int)
        /// 连接成功，但填写的模型不在服务返回的列表中，多半是模型名写错了。
        case modelNotListed(String)
        /// 连接成功，但服务没有返回任何模型。
        case noModels
        case failed(String)
    }

    private enum AIEndpointCheck: Equatable {
        case checking
        case succeeded([String])
        case failed(String)
    }

    /// 「测试连接」与「获取模型」：用面板上当前填写的接口地址与 API Key（可能尚未保存）查询服务提供的模型。
    /// 新的检查取代进行中的检查；返回在后台进行的查询任务，没有可用的查询服务时为 nil。
    @discardableResult
    func checkAIEndpoint(_ target: AIEndpointTarget) -> Task<Void, Never>? {
        guard let listAIModels else { return nil }
        resetAIEndpointCheck(target)
        let generation = aiEndpointCheckGenerations[target, default: 0]
        let baseURLString = settings[keyPath: target.baseURL]
        let apiKey = apiKeyInput(for: target)
        aiEndpointChecks[target] = .checking
        let task = Task { [weak self] in
            let check: AIEndpointCheck
            do {
                let models = try await listAIModels.execute(baseURLString: baseURLString, apiKey: apiKey)
                check = .succeeded(models)
            } catch {
                check = .failed(SettingsViewModel.checkFailureMessage(for: error))
            }
            guard let self, self.aiEndpointCheckGenerations[target, default: 0] == generation else { return }
            self.aiEndpointChecks[target] = check
            self.aiEndpointCheckTasks[target] = nil
        }
        aiEndpointCheckTasks[target] = task
        return task
    }

    /// 最近一次检查的结果；未检查或接口地址、API Key 改动后为 nil。模型名随时按当前填写的内容核对。
    func aiEndpointStatus(for target: AIEndpointTarget) -> AIEndpointStatus? {
        switch aiEndpointChecks[target] {
        case nil:
            return nil
        case .checking:
            return .checking
        case .failed(let reason):
            return .failed(reason)
        case .succeeded(let models):
            guard !models.isEmpty else { return .noModels }
            let model = settings[keyPath: target.model].trimmingCharacters(in: .whitespacesAndNewlines)
            return model.isEmpty || models.contains(model) ? .connected(modelCount: models.count) : .modelNotListed(model)
        }
    }

    /// 最近一次检查取到的模型，供「获取模型」列出选择；没有时为空。
    func availableModels(for target: AIEndpointTarget) -> [String] {
        guard case .succeeded(let models)? = aiEndpointChecks[target] else { return [] }
        return models
    }

    /// 在「获取模型」列出的模型中选择一个，填入模型名。
    func selectModel(_ model: String, for target: AIEndpointTarget) {
        settings[keyPath: target.model] = model
    }

    /// 三个全局快捷键：各自有设置值、提示与激活闭包，组合互不相同。App 层启动时按此逐个注册。
    enum ShortcutTarget: CaseIterable {
        case launcher
        case translator
        case screenTranslator

        var setting: WritableKeyPath<AppSettings, GlobalShortcut> {
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
    private func applyShortcut(_ shortcut: GlobalShortcut, to target: ShortcutTarget) {
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
            let reason = Self.reason(of: error)
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

    /// 快捷键的激活闭包；未注入（测试自建的设置模型、未提供划词翻译依赖）时为 nil。
    func activator(for target: ShortcutTarget) -> ((GlobalShortcut) throws -> Void)? {
        switch target {
        case .launcher: launcherShortcutActivator
        case .translator: translatorShortcutActivator
        case .screenTranslator: screenTranslatorShortcutActivator
        }
    }

    private func notice(for target: ShortcutTarget) -> GlobalShortcutNotice? {
        switch target {
        case .launcher: launcherShortcutNotice
        case .translator: translatorShortcutNotice
        case .screenTranslator: screenTranslatorShortcutNotice
        }
    }

    private func setNotice(_ notice: GlobalShortcutNotice?, for target: ShortcutTarget) {
        switch target {
        case .launcher: launcherShortcutNotice = notice
        case .translator: translatorShortcutNotice = notice
        case .screenTranslator: screenTranslatorShortcutNotice = notice
        }
    }

    /// 与已保存的值相同则不写入，避免逐次访问钥匙串。
    private func commit(_ apiKey: String, savedAs savedKey: inout String, to store: any APIKeyStoring) {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != savedKey else { return }
        store.save(trimmed)
        savedKey = trimmed
    }

    /// 展示给用户的失败原因：优先取本地化描述。
    private static func reason(of error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    /// 面板上当前输入的 API Key，可能尚未保存到钥匙串。
    private func apiKeyInput(for target: AIEndpointTarget) -> String {
        switch target {
        case .quickAI: quickAIAPIKey
        case .translation: translationAPIKey
        }
    }

    /// 清除检查结果并丢弃进行中的检查。
    private func resetAIEndpointCheck(_ target: AIEndpointTarget) {
        aiEndpointCheckTasks[target]?.cancel()
        aiEndpointCheckTasks[target] = nil
        aiEndpointCheckGenerations[target, default: 0] += 1
        if aiEndpointChecks[target] != nil {
            aiEndpointChecks[target] = nil
        }
    }

    private static func checkFailureMessage(for error: Error) -> String {
        switch error as? ApplicationError {
        case .aiNotConfigured?: "请先填写有效的接口地址"
        case .aiRequestFailed(let reason)?: reason
        default: "连接失败，请重试"
        }
    }
}
