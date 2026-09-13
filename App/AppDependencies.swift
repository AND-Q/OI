import Foundation

/// 具体的依赖图。这里是唯一创建基础设施适配器的地方。
@MainActor
struct AppDependencies {
    let launcherViewModel: LauncherViewModel
    let applicationIconProvider: any ApplicationIconProviding
    let globalShortcutService: any GlobalShortcutHandling
    /// 持有引用以确保目录事件在整个应用生命周期内持续送达。
    private let appDirectoryWatcher: AppDirectoryWatcher

    static func live(configuration: AppConfiguration) -> AppDependencies {
        let catalog = FileSystemAppCatalog(
            searchDirectories: configuration.applicationSearchDirectories
        )
        let applicationLauncher = WorkspaceApplicationLauncher()
        let usageStore = UserDefaultsAppUsageStore()
        let launcherViewModel = LauncherViewModel(
            discoverApplications: DiscoverApplications(catalog: catalog),
            launchApplication: LaunchApplication(launcher: applicationLauncher),
            usageStore: usageStore,
            aliases: configuration.applicationAliases
        )

        return AppDependencies(
            launcherViewModel: launcherViewModel,
            applicationIconProvider: WorkspaceApplicationIconProvider(),
            globalShortcutService: CarbonGlobalShortcutService(),
            appDirectoryWatcher: AppDirectoryWatcher(
                directories: configuration.applicationSearchDirectories
            ) { [weak launcherViewModel] in
                Task { @MainActor in
                    launcherViewModel?.markCatalogDirty()
                }
            }
        )
    }
}
