import AppKit
import os

@MainActor
final class AppCoordinator {
    private let configuration: AppConfiguration
    private let logger: Logger
    private let dependencies: AppDependencies
    private let viewModel: LauncherViewModel
    private let shortcutService: any GlobalShortcutHandling
    private let panelController: LauncherPanelController
    private lazy var statusBarController = StatusBarController(
        onToggle: { [weak self] in self?.panelController.toggle() },
        onAbout: { [weak self] in self?.showAbout() },
        onQuit: { NSApp.terminate(nil) }
    )
    private var didStart = false

    convenience init() {
        let configuration = AppConfiguration.live
        self.init(
            configuration: configuration,
            dependencies: AppDependencies.live(configuration: configuration)
        )
    }

    init(
        configuration: AppConfiguration,
        dependencies: AppDependencies
    ) {
        self.configuration = configuration
        self.logger = Logger(
            subsystem: Bundle.main.bundleIdentifier ?? "OI",
            category: "AppCoordinator"
        )
        self.dependencies = dependencies
        self.viewModel = dependencies.launcherViewModel
        self.shortcutService = dependencies.globalShortcutService
        self.panelController = LauncherPanelController(
            viewModel: dependencies.launcherViewModel,
            iconProvider: dependencies.applicationIconProvider
        )
    }

    func start() {
        guard !didStart else { return }
        didStart = true
        NSApp.setActivationPolicy(.accessory)
        statusBarController.start()
        registerShortcut()
        viewModel.loadApps()
    }

    func stop() {
        guard didStart else { return }
        didStart = false
        shortcutService.unregister()
        panelController.stop()
        statusBarController.stop()
    }

    private func registerShortcut() {
        do {
            try shortcutService.register(
                keyCode: configuration.launcherShortcut.keyCode,
                modifiers: configuration.launcherShortcut.modifiers,
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

    private func showAbout() {
        NSApp.activate()
        NSApp.orderFrontStandardAboutPanel(nil)
    }
}
