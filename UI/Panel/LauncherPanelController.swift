import AppKit
import Carbon.HIToolbox
import Combine
import SwiftUI

@MainActor
final class LauncherPanelController {
    private enum Layout {
        /// Gap between the menu bar and the panel's top edge, matching Spotlight.
        static let topGap: CGFloat = 94
        static let resizeAnimationDuration: TimeInterval = 0.18
    }

    private let viewModel: LauncherViewModel
    private let iconProvider: any ApplicationIconProviding
    private let panel: LauncherPanel
    private var keyMonitor: Any?
    private var cancellables = Set<AnyCancellable>()
    private var activeScreen: NSScreen?

    init(
        viewModel: LauncherViewModel,
        iconProvider: any ApplicationIconProviding
    ) {
        self.viewModel = viewModel
        self.iconProvider = iconProvider

        let compactRect = NSRect(
            x: 0,
            y: 0,
            width: LauncherLayout.width,
            height: LauncherLayout.searchHeight
        )
        panel = LauncherPanel(
            contentRect: compactRect,
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

        // Dismiss when the panel loses key focus (clicking the desktop or another
        // app), matching native Spotlight's default behavior.
        panel.onResignKey = { [weak self] in self?.hide() }

        let launcherView = LauncherView(
            viewModel: viewModel,
            iconProvider: iconProvider,
            onLaunch: { [weak self] app in self?.launch(app) },
            onDismiss: { [weak self] in self?.hide() }
        )
        let hostingView = NSHostingView(rootView: launcherView)
        hostingView.autoresizingMask = [.width, .height]
        panel.contentView = hostingView

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleKeyDown(event) ?? event
        }

        // Grow/shrink the window in step with the SwiftUI layout.
        viewModel.$panelHeight
            .sink { [weak self] height in
                self?.resizePanel(to: height, animated: true)
            }
            .store(in: &cancellables)
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
        cancellables.removeAll()
        viewModel.cancelOperations()
        hide()
    }

    func toggle() {
        isVisible ? hide() : show()
    }

    func show() {
        viewModel.prepareForPresentation()

        activeScreen = targetScreen()
        panel.setFrame(
            desiredFrame(for: activeScreen, height: viewModel.panelHeight),
            display: true
        )
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        viewModel.requestFocus()
    }

    func hide() {
        panel.orderOut(nil)
        NSApp.deactivate()
    }

    private func resizePanel(to height: CGFloat, animated: Bool) {
        guard panel.isVisible else { return }

        let target = desiredFrame(for: resolvedScreen(), height: height)
        guard target.size != panel.frame.size else { return }

        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Layout.resizeAnimationDuration
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().setFrame(target, display: true)
            }
        } else {
            panel.setFrame(target, display: true)
        }
    }

    private func targetScreen() -> NSScreen? {
        let mouseLocation = NSEvent.mouseLocation
        return NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) }) ?? NSScreen.main
    }

    /// Keeps the screen picked at show() so the panel never jumps to another display
    /// mid-session; re-selects only if that display was disconnected.
    private func resolvedScreen() -> NSScreen? {
        if let activeScreen, NSScreen.screens.contains(activeScreen) {
            return activeScreen
        }
        activeScreen = targetScreen()
        return activeScreen
    }

    /// The panel keeps a fixed top edge and horizontal center; its height grows downward,
    /// exactly like the native Spotlight panel.
    private func desiredFrame(for screen: NSScreen?, height: CGFloat) -> NSRect {
        let visibleFrame = screen?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let size = NSSize(
            width: LauncherLayout.width,
            height: height
        )
        let origin = NSPoint(
            x: visibleFrame.midX - size.width / 2,
            y: visibleFrame.maxY - Layout.topGap - size.height
        )
        return NSRect(origin: origin, size: size)
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
    /// Invoked when the panel loses key window status.
    var onResignKey: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func resignKey() {
        super.resignKey()
        onResignKey?()
    }
}
