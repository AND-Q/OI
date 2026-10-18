import AppKit
import os

@MainActor
final class AppCoordinator {
    private let logger: Logger
    private let dependencies: AppDependencies
    private let viewModel: LauncherViewModel
    private let shortcutService: any GlobalShortcutHandling
    private let panelController: LauncherPanelController
    private let translatorPanelController: TranslatorPanelController?
    private lazy var statusBarController = StatusBarController(
        onShowLauncher: { [weak self] in self?.panelController.show() },
        onSettings: { [weak self] in self?.showSettings() },
        onAbout: { [weak self] in self?.showAbout() },
        onQuit: { NSApp.terminate(nil) }
    )
    private lazy var settingsWindowController = SettingsWindowController(
        viewModel: dependencies.settingsViewModel
    )
    private var didStart = false
    /// 标准关于面板没有公开的窗口引用，首次展示时记下以便之后置顶。
    private weak var aboutWindow: NSWindow?

    convenience init() {
        self.init(
            dependencies: AppDependencies.live(configuration: .live)
        )
    }

    init(dependencies: AppDependencies) {
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
        self.translatorPanelController = dependencies.translator.map {
            TranslatorPanelController(makeViewModel: $0.makeViewModel)
        }
        // 设置面板切换呼出快捷键时经由同一注册路径生效。直接强引用服务与面板：
        // 闭包被调用时面板必须存在（否则注册出的热键呼不出任何东西），
        // 也避免弱引用失效时「正常返回」被调用方误判为注册成功。
        // 代价是协调者与依赖图之间形成引用环（本对象 → 依赖 → 设置模型 → 本对象），
        // 这里刻意接受：协调者与依赖图同寿命，环不会延长任何对象的存活时间。
        let shortcutService = self.shortcutService
        let panelController = self.panelController
        dependencies.settingsViewModel.launcherShortcutActivator = { shortcut in
            try shortcutService.register(
                keyCode: shortcut.keyCode,
                modifiers: shortcut.modifiers,
                handler: {
                    Task { @MainActor in
                        panelController.toggle()
                    }
                }
            )
        }
        // 启动时文件搜索关闭、之后才在设置中开启的，开启时补一次目录授权请求。
        dependencies.settingsViewModel.fileSearchAccessRequester = dependencies.fileSearchAccessRequester
        // 翻译快捷键沿用同样的注册路径与强引用约定。
        if let translatorShortcutService = dependencies.translator?.shortcutService,
           let translatorPanelController {
            dependencies.settingsViewModel.translatorShortcutActivator = { shortcut in
                try translatorShortcutService.register(
                    keyCode: shortcut.keyCode,
                    modifiers: shortcut.modifiers,
                    handler: {
                        Task { @MainActor in
                            translatorPanelController.toggleShortcutTranslation()
                        }
                    }
                )
            }
        }
        if let screenShortcutService = dependencies.translator?.screenShortcutService,
           let translatorPanelController {
            dependencies.settingsViewModel.screenTranslatorShortcutActivator = { shortcut in
                try screenShortcutService.register(
                    keyCode: shortcut.keyCode,
                    modifiers: shortcut.modifiers,
                    handler: {
                        Task { @MainActor in
                            translatorPanelController.toggleScreenTranslation()
                        }
                    }
                )
            }
        }
        // 用力点按监听随设置启停：关闭时不安装全局事件监听，也不在未授权时轮询重试。
        if let forceTouchMonitor = dependencies.translator?.forceTouchMonitor,
           let translatorPanelController {
            dependencies.settingsViewModel.forceTouchTranslationActivator = { isEnabled in
                guard isEnabled else {
                    forceTouchMonitor.stop()
                    return
                }
                forceTouchMonitor.start { point in
                    translatorPanelController.translateText(at: point)
                }
            }
        }
    }

    func start() {
        guard !didStart else { return }
        didStart = true
        NSApp.setActivationPolicy(.accessory)
        statusBarController.start()
        registerLauncherShortcut()
        registerTranslatorShortcut()
        registerScreenTranslatorShortcut()
        if dependencies.settingsStore.load().isForceTouchTranslationEnabled {
            dependencies.settingsViewModel.forceTouchTranslationActivator?(true)
        }
        viewModel.loadApps()
        // 文件搜索开启时才触发目录授权，否则会缺少桌面、文稿、下载下的结果；关闭时不打扰用户。
        if dependencies.settingsStore.load().isFileSearchEnabled {
            dependencies.fileSearchAccessRequester?()
        }
        // 静默启动关闭时，启动后自动呼出启动器面板。
        if !dependencies.settingsStore.load().isSilentLaunchEnabled {
            panelController.show()
        }
    }

    func stop() {
        guard didStart else { return }
        didStart = false
        shortcutService.unregister()
        dependencies.translator?.shortcutService.unregister()
        dependencies.translator?.screenShortcutService.unregister()
        dependencies.translator?.forceTouchMonitor.stop()
        panelController.stop()
        translatorPanelController?.stop()
        statusBarController.stop()
        settingsWindowController.close()
    }

    /// 按用户设置注册呼出快捷键；失败（如组合被其他应用占用）时保持未注册，
    /// 记录日志并把原因同步到设置面板，避免用户面对一个静默失效的快捷键。
    private func registerLauncherShortcut() {
        // 激活闭包由协调者在构造时注入；缺失只可能来自测试自建的设置模型。
        guard let activator = dependencies.settingsViewModel.launcherShortcutActivator else {
            return
        }
        let shortcut = dependencies.settingsStore.load().launcherShortcut
        do {
            try activator(shortcut)
        } catch {
            logger.error("Global shortcut registration failed: \(error.localizedDescription, privacy: .public)")
            dependencies.settingsViewModel.reportShortcutRegistrationFailure(error)
        }
    }

    /// 按用户设置注册翻译快捷键；失败处理与呼出快捷键一致。
    private func registerTranslatorShortcut() {
        guard let activator = dependencies.settingsViewModel.translatorShortcutActivator else {
            return
        }
        let shortcut = dependencies.settingsStore.load().translatorShortcut
        do {
            try activator(shortcut)
        } catch {
            logger.error("Translator shortcut registration failed: \(error.localizedDescription, privacy: .public)")
            dependencies.settingsViewModel.reportTranslatorShortcutRegistrationFailure(error)
        }
    }

    /// 按用户设置注册截图翻译快捷键；失败处理与呼出快捷键一致。
    private func registerScreenTranslatorShortcut() {
        guard let activator = dependencies.settingsViewModel.screenTranslatorShortcutActivator else {
            return
        }
        let shortcut = dependencies.settingsStore.load().screenTranslatorShortcut
        do {
            try activator(shortcut)
        } catch {
            logger.error("Screen translator shortcut registration failed: \(error.localizedDescription, privacy: .public)")
            dependencies.settingsViewModel.reportScreenTranslatorShortcutRegistrationFailure(error)
        }
    }

    func showSettings() {
        settingsWindowController.show()
    }

    private func showAbout() {
        // 与设置窗口相同：推迟到状态栏菜单收起后再激活，并强制置顶，避免被其他应用压住。
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let existingWindows = Set(NSApp.windows.map(ObjectIdentifier.init))
            NSApp.activate()
            // 空字符串让系统不在版本号后附带括号中的 build 号
            NSApp.orderFrontStandardAboutPanel(options: [.version: ""])
            if self.aboutWindow == nil {
                self.aboutWindow = NSApp.windows.first { !existingWindows.contains(ObjectIdentifier($0)) }
            }
            self.aboutWindow?.orderFrontRegardless()
        }
    }
}
