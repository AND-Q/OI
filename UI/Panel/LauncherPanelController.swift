import AppKit
import Carbon.HIToolbox
import SwiftUI

@MainActor
final class LauncherPanelController {
    private let viewModel: LauncherViewModel
    private let iconProvider: any ApplicationIconProviding
    private let panel: LauncherPanel
    private var keyMonitor: Any?

    init(
        viewModel: LauncherViewModel,
        iconProvider: any ApplicationIconProviding
    ) {
        self.viewModel = viewModel
        self.iconProvider = iconProvider

        panel = LauncherPanel(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 386),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false

        let launcherView = LauncherView(
            viewModel: viewModel,
            iconProvider: iconProvider,
            onLaunch: { [weak self] app in self?.launch(app) },
            onDismiss: { [weak self] in self?.hide() }
        )
        let hostingView = NSHostingView(rootView: launcherView)
        hostingView.frame = panel.contentView?.bounds ?? .zero
        hostingView.autoresizingMask = [.width, .height]
        panel.contentView = hostingView

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleKeyDown(event) ?? event
        }
    }

    deinit {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
        }
    }

    var isVisible: Bool { panel.isVisible }

    func stop() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        viewModel.cancelOperations()
        hide()
    }

    func toggle() {
        isVisible ? hide() : show()
    }

    func show() {
        viewModel.prepareForPresentation()

        let mouseLocation = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) }) ?? NSScreen.main
        let visibleFrame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let origin = NSPoint(
            x: visibleFrame.midX - panel.frame.width / 2,
            y: visibleFrame.midY + visibleFrame.height * 0.18 - panel.frame.height / 2
        )

        panel.setFrameOrigin(origin)
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        viewModel.requestFocus()
    }

    func hide() {
        panel.orderOut(nil)
        NSApp.deactivate()
    }

    private func handleKeyDown(_ event: NSEvent) -> NSEvent? {
        guard panel.isVisible else { return event }

        switch event.keyCode {
        case UInt16(kVK_Escape):
            hide()
            return nil
        case UInt16(kVK_Return), UInt16(kVK_ANSI_KeypadEnter):
            if let app = viewModel.selectedApp {
                launch(app)
            }
            return nil
        case UInt16(kVK_UpArrow):
            viewModel.moveSelection(by: -1)
            return nil
        case UInt16(kVK_DownArrow):
            viewModel.moveSelection(by: 1)
            return nil
        default:
            return event
        }
    }

    private func launch(_ app: AppDescriptor) {
        viewModel.launch(app)
        hide()
    }
}

final class LauncherPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
