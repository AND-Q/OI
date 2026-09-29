import AppKit

@MainActor
final class StatusBarController: NSObject {
    private(set) var statusItem: NSStatusItem?
    private(set) var contextMenu: NSMenu?
    private let onShowLauncher: () -> Void
    private let onSettings: () -> Void
    private let onAbout: () -> Void
    private let onQuit: () -> Void

    init(
        onShowLauncher: @escaping () -> Void,
        onSettings: @escaping () -> Void,
        onAbout: @escaping () -> Void,
        onQuit: @escaping () -> Void
    ) {
        self.onShowLauncher = onShowLauncher
        self.onSettings = onSettings
        self.onAbout = onAbout
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
            title: "显示启动器",
            action: #selector(showLauncher),
            keyEquivalent: ""
        )
        let aboutItem = NSMenuItem(title: "关于 OI", action: #selector(about), keyEquivalent: "")
        let settingsItem = NSMenuItem(
            title: "设置…",
            action: #selector(settings),
            keyEquivalent: ","
        )
        let quitItem = NSMenuItem(title: "退出", action: #selector(quit), keyEquivalent: "q")
        showItem.target = self
        aboutItem.target = self
        settingsItem.target = self
        quitItem.target = self

        menu.addItem(showItem)
        menu.addItem(.separator())
        menu.addItem(aboutItem)
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

    @objc func settings() {
        onSettings()
    }

    @objc func quit() {
        onQuit()
    }
}
