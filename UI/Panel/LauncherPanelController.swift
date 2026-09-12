import AppKit
import Carbon.HIToolbox
import Combine
import SwiftUI

@MainActor
final class LauncherPanelController {
    private let viewModel: LauncherViewModel
    private let iconProvider: any ApplicationIconProviding
    private let panel: LauncherPanel
    private let animationCoordinator: PanelAnimationCoordinator
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

        animationCoordinator = PanelAnimationCoordinator(
            panel: panel,
            initialHeight: LauncherLayout.searchHeight
        )

        // Dismiss when the panel loses key focus (clicking the desktop or another
        // app), matching native Spotlight's default behavior.
        panel.onResignKey = { [weak self] in self?.hide() }

        let launcherView = LauncherView(
            viewModel: viewModel,
            animation: animationCoordinator,
            iconProvider: iconProvider,
            onLaunch: { [weak self] app in self?.launch(app) },
            onDismiss: { [weak self] in self?.hide() }
        )
        let hostingView = NSHostingView(rootView: launcherView)
        hostingView.autoresizingMask = [.width, .height]
        hostingView.wantsLayer = true
        hostingView.layer?.cornerRadius = LauncherLayout.compactCornerRadius
        hostingView.layer?.cornerCurve = .continuous
        hostingView.layer?.masksToBounds = true
        panel.contentView = hostingView

        if let frameView = panel.contentView?.superview {
            frameView.wantsLayer = true
            frameView.layer?.cornerRadius = LauncherLayout.compactCornerRadius
            frameView.layer?.cornerCurve = .continuous
            frameView.layer?.masksToBounds = true
        }

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return self.handleKeyDown(event)
        }

        // Grow/shrink the window in step with the SwiftUI layout.
        viewModel.$panelHeight
            .sink { [weak self] height in
                self?.resizePanel(to: height)
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
        animationCoordinator.stopAnimations()
        panel.orderOut(nil)
        viewModel.cancelOperations()
    }

    func toggle() {
        // During an in-flight fade-out route to show(): hide() would drop the
        // request, leaving the hotkey press swallowed.
        (isVisible && !animationCoordinator.isDismissalInProgress) ? hide() : show()
    }

    func show() {
        guard !panel.isVisible else {
            // Already showing: refocus instead of resetting the session. Reverse
            // an in-flight fade-out first, or its completion would order the
            // panel out right after this wake.
            animationCoordinator.cancelDismissal()
            panel.makeKeyAndOrderFront(nil)
            viewModel.requestFocus()
            return
        }

        viewModel.prepareForPresentation()

        activeScreen = targetScreen()
        animationCoordinator.screen = activeScreen
        let height = viewModel.panelHeight
        panel.setFrame(
            PanelAnimationCoordinator.frame(for: activeScreen, height: height),
            display: true
        )
        animationCoordinator.prepareForPresentation(height: height)
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.invalidateShadow()
        animationCoordinator.fadeIn()
        viewModel.requestFocus()
    }

    func hide() {
        guard panel.isVisible, !animationCoordinator.isDismissalInProgress else { return }
        animationCoordinator.fadeOutAndOrderOut()
        NSApp.deactivate()
    }

    private func resizePanel(to height: CGFloat) {
        guard panel.isVisible else { return }

        animationCoordinator.screen = resolvedScreen()
        let target = PanelAnimationCoordinator.frame(
            for: animationCoordinator.screen,
            height: height
        )
        guard target.size != panel.frame.size else { return }

        animationCoordinator.resize(toHeight: height)
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

    private func handleKeyDown(_ event: NSEvent) -> NSEvent? {
        guard panel.isVisible else { return event }

        // When the focused field editor has marked text (e.g. active Pinyin/IME composition),
        // let the input method handle all keys: Return commits the composition, Escape aborts it,
        // and arrow keys browse candidate words.
        if hasActiveMarkedText {
            return event
        }

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

    private var hasActiveMarkedText: Bool {
        if let client = panel.firstResponder as? NSTextInputClient, client.hasMarkedText() {
            return true
        }
        if let fieldEditor = panel.fieldEditor(false, for: nil) as? NSTextInputClient, fieldEditor.hasMarkedText() {
            return true
        }
        return false
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
