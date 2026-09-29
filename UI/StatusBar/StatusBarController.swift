import AppKit

@MainActor
final class StatusBarController: NSObject, NSMenuDelegate {
    private(set) var statusItem: NSStatusItem?
    private(set) var contextMenu: NSMenu?
    private let onToggle: () -> Void
    private let onSettings: () -> Void
    private let onAbout: () -> Void
    private let onQuit: () -> Void

    init(
        onToggle: @escaping () -> Void,
        onSettings: @escaping () -> Void,
        onAbout: @escaping () -> Void,
        onQuit: @escaping () -> Void
    ) {
        self.onToggle = onToggle
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
                accessibilityDescription: "App Launcher"
            )
            button.target = self
            button.action = #selector(handleStatusItemClick(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        let menu = NSMenu()
        menu.delegate = self

        let aboutItem = NSMenuItem(title: "关于 OI", action: #selector(about), keyEquivalent: "")
        let settingsItem = NSMenuItem(
            title: "设置…",
            action: #selector(settings),
            keyEquivalent: ","
        )
        let quitItem = NSMenuItem(title: "退出", action: #selector(quit), keyEquivalent: "q")
        aboutItem.target = self
        settingsItem.target = self
        quitItem.target = self

        menu.addItem(aboutItem)
        menu.addItem(settingsItem)
        menu.addItem(.separator())
        menu.addItem(quitItem)

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

    @objc func handleStatusItemClick(_ sender: NSStatusBarButton) {
        handleStatusItemClick(with: NSApp.currentEvent)
    }

    func handleStatusItemClick(with event: NSEvent?) {
        let isRightClick = event?.type == .rightMouseUp ||
            (event?.type == .leftMouseUp && event?.modifierFlags.contains(.control) == true)

        if isRightClick, let contextMenu {
            statusItem?.menu = contextMenu
            statusItem?.button?.performClick(nil)
        } else {
            onToggle()
        }
    }

    func menuDidClose(_ menu: NSMenu) {
        DispatchQueue.main.async { [weak self] in
            self?.statusItem?.menu = nil
        }
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
