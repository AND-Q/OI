import AppKit
import Carbon.HIToolbox
import os

@MainActor
final class AppCoordinator {
    private let logger = Logger(subsystem: "com.example.OI", category: "AppCoordinator")
    private let viewModel: LauncherViewModel
    private let shortcutService: any GlobalShortcutHandling
    private let panelController: LauncherPanelController
    private var statusBarController: StatusBarController?
    private var didStart = false

    convenience init() {
        let applicationLauncher = WorkspaceApplicationLauncher()
        self.init(
            viewModel: LauncherViewModel(
                discoverApplications: DiscoverApplications(catalog: FileSystemAppCatalog()),
                launchApplication: LaunchApplication(launcher: applicationLauncher)
            ),
            iconProvider: WorkspaceApplicationIconProvider(),
            shortcutService: CarbonGlobalShortcutService()
        )
    }

    init(
        viewModel: LauncherViewModel,
        iconProvider: any ApplicationIconProviding,
        shortcutService: any GlobalShortcutHandling
    ) {
        self.viewModel = viewModel
        self.shortcutService = shortcutService
        self.panelController = LauncherPanelController(
            viewModel: viewModel,
            iconProvider: iconProvider
        )
        self.statusBarController = nil
        self.statusBarController = StatusBarController(
            onShow: { [weak self] in self?.panelController.show() },
            onQuit: { NSApp.terminate(nil) }
        )
    }

    func start() {
        guard !didStart else { return }
        didStart = true
        NSApp.setActivationPolicy(.accessory)
        statusBarController?.start()
        registerShortcut()
        viewModel.loadApps()
    }

    func stop() {
        guard didStart else { return }
        didStart = false
        shortcutService.unregister()
        panelController.stop()
        statusBarController?.stop()
    }

    private func registerShortcut() {
        do {
            try shortcutService.register(
                keyCode: UInt32(kVK_Space),
                modifiers: UInt32(optionKey),
                handler: { [weak self] in
                    Task { @MainActor in
                        self?.panelController.toggle()
                    }
                }
            )
        } catch {
            logger.error("Global shortcut registration failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
