import Foundation

/// 具体的依赖图。这里是唯一创建基础设施适配器的地方。
@MainActor
struct AppDependencies {
    let launcherViewModel: LauncherViewModel
    let settingsViewModel: SettingsViewModel
    let settingsStore: any AppSettingsStoring
    let applicationIconProvider: any ApplicationIconProviding
    let globalShortcutService: any GlobalShortcutHandling
    /// 持有引用以确保目录事件在整个应用生命周期内持续送达；测试注入依赖图时可省略，
    /// 此时不监听目录变动。
    var appDirectoryWatcher: AppDirectoryWatcher? = nil
    /// 划词翻译；测试注入依赖图时可省略，此时不注册翻译快捷键、不监听触控板用力点按。
    var translator: TranslatorDependencies? = nil
    /// 请求文件搜索所需的桌面、文稿、下载目录授权，由协调者在文件搜索开启时调用；
    /// 测试注入依赖图时可省略，此时不触发授权。
    var fileSearchAccessRequester: (() -> Void)? = nil
    /// 检查更新；测试注入依赖图时可省略，此时菜单栏的「检查更新…」不做任何事。
    var updates: UpdateDependencies? = nil

    static func live(configuration: AppConfiguration) -> AppDependencies {
        let settingsStore = UserDefaultsAppSettingsStore()
        let catalog = FileSystemAppCatalog(
            searchDirectories: configuration.applicationSearchDirectories
        )
        let applicationLauncher = WorkspaceApplicationLauncher()
        let fileSearcher = SpotlightFileSearcher()
        let fileOpener = WorkspaceFileOpener()
        let urlOpener = WorkspaceURLOpener()
        let openURL = OpenURL(opener: urlOpener)
        let usageStore = UserDefaultsAppUsageStore()
        let quickAIKeyStore = KeychainQuickAIKeyStore()
        let translatorKeyStore = KeychainQuickAIKeyStore(
            account: KeychainQuickAIKeyStore.translatorAccount,
            initialValueAccount: KeychainQuickAIKeyStore.quickAIAccount
        )
        let quickAIClient = OpenAICompatibleQuickAIClient()
        let translatorEnvironment = SystemTranslatorEnvironment()
        let textCapturer = AccessibilityTextCapturer()
        let launcherViewModel = LauncherViewModel(
            discoverApplications: DiscoverApplications(catalog: catalog),
            launchApplication: LaunchApplication(launcher: applicationLauncher),
            searchFiles: SearchFiles(
                searcher: fileSearcher,
                limit: configuration.fileSearchResultLimit
            ),
            openFile: OpenFile(opener: fileOpener),
            openURL: openURL,
            askQuickAI: AskQuickAI(
                answerer: quickAIClient,
                settingsStore: settingsStore,
                keyStore: quickAIKeyStore
            ),
            usageStore: usageStore,
            settingsStore: settingsStore,
            notifier: UserNotificationCenterNotifier(),
            aliases: configuration.applicationAliases,
            fileSearchMinimumQueryLength: configuration.fileSearchMinimumQueryLength
        )
        let translateText = TranslateText(
            answerer: quickAIClient,
            languageDetector: NaturalLanguageDetector(),
            settingsStore: settingsStore,
            keyStore: translatorKeyStore
        )
        let wordSelector = DoubleClickWordSelector(textCapturer: textCapturer)
        let screenTextRecognizer = VisionScreenTextRecognizer()

        return AppDependencies(
            launcherViewModel: launcherViewModel,
            settingsViewModel: SettingsViewModel(
                settingsStore: settingsStore,
                loginItemController: SMAppServiceLoginItemController(),
                quickAIKeyStore: quickAIKeyStore,
                translatorKeyStore: translatorKeyStore,
                translatorEnvironment: translatorEnvironment
            ),
            settingsStore: settingsStore,
            applicationIconProvider: WorkspaceApplicationIconProvider(),
            globalShortcutService: CarbonGlobalShortcutService(hotKeyIdentifier: 1),
            appDirectoryWatcher: AppDirectoryWatcher(
                directories: configuration.applicationSearchDirectories
            ) { [weak launcherViewModel] in
                Task { @MainActor in
                    launcherViewModel?.markCatalogDirty()
                }
            },
            translator: TranslatorDependencies(
                makeViewModel: {
                    TranslatorViewModel(
                        translateText: translateText,
                        textCapturer: textCapturer,
                        wordSelector: wordSelector,
                        screenTextRecognizer: screenTextRecognizer,
                        environment: translatorEnvironment,
                        settingsStore: settingsStore
                    )
                },
                shortcutService: CarbonGlobalShortcutService(hotKeyIdentifier: 2),
                screenShortcutService: CarbonGlobalShortcutService(hotKeyIdentifier: 3),
                forceTouchMonitor: GlobalForceTouchMonitor()
            ),
            fileSearchAccessRequester: { fileSearcher.requestProtectedFolderAccess() },
            updates: UpdateDependencies(
                checkForUpdates: CheckForUpdates(
                    fetcher: GitHubReleaseFetcher(repository: configuration.releaseRepository),
                    currentVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
                        as? String ?? ""
                ),
                openURL: openURL
            )
        )
    }
}

/// 划词翻译的依赖。翻译与截图翻译快捷键各使用独立的热键服务实例，与呼出快捷键按热键 ID 区分。
@MainActor
struct TranslatorDependencies {
    /// 每个翻译气泡各建一份视图模型：固定的气泡保留自己的内容，与之后的翻译互不影响。
    let makeViewModel: @MainActor () -> TranslatorViewModel
    let shortcutService: any GlobalShortcutHandling
    let screenShortcutService: any GlobalShortcutHandling
    let forceTouchMonitor: any ForceTouchMonitoring
}

/// 检查更新的依赖：查询最新发布的版本，有新版本时在浏览器中打开发布页。
@MainActor
struct UpdateDependencies {
    let checkForUpdates: CheckForUpdates
    let openURL: OpenURL
}
