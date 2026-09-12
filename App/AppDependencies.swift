import Foundation

/// Concrete dependency graph. This is the only place that creates infrastructure adapters.
@MainActor
struct AppDependencies {
    let launcherViewModel: LauncherViewModel
    let applicationIconProvider: any ApplicationIconProviding
    let globalShortcutService: any GlobalShortcutHandling
    /// Retained so directory events keep arriving for the app lifetime.
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
