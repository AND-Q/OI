import Foundation

/// Concrete dependency graph. This is the only place that creates infrastructure adapters.
@MainActor
struct AppDependencies {
    let launcherViewModel: LauncherViewModel
    let applicationIconProvider: any ApplicationIconProviding
    let globalShortcutService: any GlobalShortcutHandling

    static func live(configuration: AppConfiguration) -> AppDependencies {
        let catalog = FileSystemAppCatalog(
            searchDirectories: configuration.applicationSearchDirectories
        )
        let applicationLauncher = WorkspaceApplicationLauncher()

        return AppDependencies(
            launcherViewModel: LauncherViewModel(
                discoverApplications: DiscoverApplications(catalog: catalog),
                launchApplication: LaunchApplication(launcher: applicationLauncher)
            ),
            applicationIconProvider: WorkspaceApplicationIconProvider(),
            globalShortcutService: CarbonGlobalShortcutService()
        )
    }
}
