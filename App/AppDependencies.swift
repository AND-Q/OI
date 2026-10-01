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

    static func live(configuration: AppConfiguration) -> AppDependencies {
        let settingsStore = UserDefaultsAppSettingsStore()
        let catalog = FileSystemAppCatalog(
            searchDirectories: configuration.applicationSearchDirectories
        )
        let applicationLauncher = WorkspaceApplicationLauncher()
        let fileSearcher = SpotlightFileSearcher()
        // 首次启动即触发目录授权，否则文件搜索会缺少桌面、文稿、下载下的结果。
        fileSearcher.requestProtectedFolderAccess()
        let fileOpener = WorkspaceFileOpener()
        let urlOpener = WorkspaceURLOpener()
        let usageStore = UserDefaultsAppUsageStore()
        let quickAIKeyStore = KeychainQuickAIKeyStore()
        let quickAIClient = OpenAICompatibleQuickAIClient()
        let translatorEnvironment = SystemTranslatorEnvironment()
        let launcherViewModel = LauncherViewModel(
            discoverApplications: DiscoverApplications(catalog: catalog),
            launchApplication: LaunchApplication(launcher: applicationLauncher),
            searchFiles: SearchFiles(
                searcher: fileSearcher,
                limit: configuration.fileSearchResultLimit
            ),
            openFile: OpenFile(opener: fileOpener),
            openURL: OpenURL(opener: urlOpener),
            askQuickAI: AskQuickAI(
                answerer: quickAIClient,
                settingsStore: settingsStore,
                keyStore: quickAIKeyStore
            ),
            usageStore: usageStore,
            settingsStore: settingsStore,
            aliases: configuration.applicationAliases,
            fileSearchMinimumQueryLength: configuration.fileSearchMinimumQueryLength
        )

        return AppDependencies(
            launcherViewModel: launcherViewModel,
            settingsViewModel: SettingsViewModel(
                settingsStore: settingsStore,
                loginItemController: SMAppServiceLoginItemController(),
                quickAIKeyStore: quickAIKeyStore,
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
                viewModel: TranslatorViewModel(
                    translateText: TranslateText(
                        answerer: quickAIClient,
                        languageDetector: NaturalLanguageDetector(),
                        settingsStore: settingsStore,
                        keyStore: quickAIKeyStore
                    ),
                    textCapturer: AccessibilityTextCapturer(),
                    screenWordRecognizer: VisionScreenWordRecognizer(),
                    environment: translatorEnvironment,
                    settingsStore: settingsStore
                ),
                shortcutService: CarbonGlobalShortcutService(hotKeyIdentifier: 2),
                forceTouchMonitor: GlobalForceTouchMonitor()
            )
        )
    }
}

/// 划词翻译的依赖。翻译快捷键使用独立的热键服务实例，与呼出快捷键按热键 ID 区分。
@MainActor
struct TranslatorDependencies {
    let viewModel: TranslatorViewModel
    let shortcutService: any GlobalShortcutHandling
    let forceTouchMonitor: any ForceTouchMonitoring
}
