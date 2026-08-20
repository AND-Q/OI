import AppKit

@MainActor
final class StatusBarController {
    private var statusItem: NSStatusItem?
    private let onShow: () -> Void
    private let onQuit: () -> Void

    init(onShow: @escaping () -> Void, onQuit: @escaping () -> Void) {
        self.onShow = onShow
        self.onQuit = onQuit
    }

    func start() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(
            systemSymbolName: "command",
            accessibilityDescription: "App Launcher"
        )

        let menu = NSMenu()
        let showItem = NSMenuItem(title: "显示启动器", action: #selector(showLauncher), keyEquivalent: "")
        let quitItem = NSMenuItem(title: "退出", action: #selector(quit), keyEquivalent: "q")
        showItem.target = self
        quitItem.target = self
        menu.addItem(showItem)
        menu.addItem(.separator())
        menu.addItem(quitItem)

        item.menu = menu
        statusItem = item
    }

    func stop() {
        if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
            self.statusItem = nil
        }
    }

    @objc private func showLauncher() {
        onShow()
    }

    @objc private func quit() {
        onQuit()
    }
}
