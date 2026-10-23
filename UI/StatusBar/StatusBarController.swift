import AppKit

@MainActor
final class StatusBarController: NSObject {
    private(set) var statusItem: NSStatusItem?
    private(set) var contextMenu: NSMenu?
    private let onShowLauncher: () -> Void
    private let onSettings: () -> Void
    private let onAbout: () -> Void
    private let onCheckForUpdates: () -> Void
    private let isCheckingForUpdates: () -> Bool
    private let onQuit: () -> Void

    init(
        onShowLauncher: @escaping () -> Void,
        onSettings: @escaping () -> Void,
        onAbout: @escaping () -> Void,
        onCheckForUpdates: @escaping () -> Void,
        isCheckingForUpdates: @escaping () -> Bool,
        onQuit: @escaping () -> Void
    ) {
        self.onShowLauncher = onShowLauncher
        self.onSettings = onSettings
        self.onAbout = onAbout
        self.onCheckForUpdates = onCheckForUpdates
        self.isCheckingForUpdates = isCheckingForUpdates
        self.onQuit = onQuit
        super.init()
    }

    func start() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.image = NSImage(
                systemSymbolName: "command",
                accessibilityDescription: "OI"
            )
        }

        let menu = NSMenu()
        let showItem = NSMenuItem(
            title: String(localized: "显示启动器"),
            action: #selector(showLauncher),
            keyEquivalent: ""
        )
        let aboutItem = NSMenuItem(title: String(localized: "关于 OI"), action: #selector(about), keyEquivalent: "")
        let updateItem = NSMenuItem(
            title: String(localized: "检查更新…"),
            action: #selector(checkForUpdates),
            keyEquivalent: ""
        )
        let settingsItem = NSMenuItem(
            title: String(localized: "设置…"),
            action: #selector(settings),
            keyEquivalent: ","
        )
        let quitItem = NSMenuItem(title: String(localized: "退出"), action: #selector(quit), keyEquivalent: "q")
        showItem.target = self
        aboutItem.target = self
        updateItem.target = self
        settingsItem.target = self
        quitItem.target = self

        menu.addItem(showItem)
        menu.addItem(.separator())
        menu.addItem(aboutItem)
        menu.addItem(updateItem)
        menu.addItem(settingsItem)
        menu.addItem(.separator())
        menu.addItem(quitItem)

        // 菜单常驻挂载，单击直接弹出菜单
        item.menu = menu

        self.contextMenu = menu
        self.statusItem = item
    }

    func stop() {
        if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
            self.statusItem = nil
        }
        self.contextMenu = nil
    }

    @objc func showLauncher() {
        onShowLauncher()
    }

    @objc func about() {
        onAbout()
    }

    @objc func checkForUpdates() {
        onCheckForUpdates()
    }

    @objc func settings() {
        onSettings()
    }

    @objc func quit() {
        onQuit()
    }
}

extension StatusBarController: NSMenuItemValidation {
    /// 检查更新期间该项显示「正在检查更新…」且不可点按，避免重复请求；菜单每次弹出时都会重新校验。
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard menuItem.action == #selector(checkForUpdates) else { return true }
        let isChecking = isCheckingForUpdates()
        menuItem.title = isChecking ? String(localized: "正在检查更新…") : String(localized: "检查更新…")
        return !isChecking
    }
}
