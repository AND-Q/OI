import AppKit
import Carbon.HIToolbox
import Combine
import Quartz
import SwiftUI

@MainActor
final class LauncherPanelController {
    private let viewModel: LauncherViewModel
    private let iconProvider: any ApplicationIconProviding
    let quickLook = QuickLookPresenter()
    let panel: LauncherPanel
    private let animationCoordinator: PanelAnimationCoordinator
    private var keyMonitor: Any?
    private var cancellables = Set<AnyCancellable>()
    private var activeScreen: NSScreen?
    private var lastHandledEventTimestamp: TimeInterval = 0
    private var lastHandledKeyCode: UInt16 = 0

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
        panel.becomesKeyOnlyIfNeeded = false
        panel.isMovable = false
        panel.isMovableByWindowBackground = false
        // Quick Look 经由响应链寻找接管者，接管点挂在窗口自身。
        panel.quickLookPresenter = quickLook

        animationCoordinator = PanelAnimationCoordinator(
            panel: panel,
            initialHeight: LauncherLayout.searchHeight
        )

        // Dismiss when the panel loses key focus (clicking the desktop or another
        // app), matching native Spotlight's default behavior.
        panel.onResignKey = { [weak self] in
            guard let self else { return }
            if self.quickLook.isActive,
               let keyWindow = NSApp.keyWindow,
               keyWindow === QLPreviewPanel.shared() {
                return
            }
            self.hide()
        }
        quickLook.onSessionEnded = { [weak self] in
            guard let self,
                  self.panel.isVisible,
                  !self.animationCoordinator.isDismissalInProgress else { return }
            self.panel.makeKeyAndOrderFront(nil)
            self.viewModel.requestFocus()
        }
        quickLook.onHandleEvent = { [weak self] event in
            guard let self, event.type == .keyDown else { return false }
            return self.handleKeyDown(event) == nil
        }

        let launcherView = LauncherView(
            viewModel: viewModel,
            animation: animationCoordinator,
            iconProvider: iconProvider,
            onOpen: { [weak self] result in self?.open(result) },
            onAction: { [weak self] action, result in
                self?.performMenuAction(action, for: result)
            },
            onDismiss: { [weak self] in self?.hide() }
        )
        let hostingView = NSHostingView(rootView: launcherView)
        hostingView.autoresizingMask = [.width, .height]
        panel.contentView = LauncherPanelSurface(
            contentView: hostingView,
            cornerRadius: LauncherLayout.compactCornerRadius
        )

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

        // Dismiss when user switches away to another application.
        NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)
            .sink { [weak self] _ in
                self?.hide()
            }
            .store(in: &cancellables)
    }

    isolated deinit {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
        }
    }

    var isVisible: Bool { panel.isVisible }
    var isDismissalInProgress: Bool { animationCoordinator.isDismissalInProgress }

    func stop() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        panel.orderOut(nil)
        quickLook.close()
        viewModel.dismissActionSheet()
        cancellables.removeAll()
        animationCoordinator.stopAnimations()
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
            NSApp.activate(ignoringOtherApps: true)
            animationCoordinator.cancelDismissal()
            activeScreen = targetScreen()
            animationCoordinator.screen = activeScreen
            let height = animationCoordinator.currentHeight
            panel.setFrame(
                PanelAnimationCoordinator.frame(for: activeScreen, height: height),
                display: true
            )
            panel.makeKeyAndOrderFront(nil)
            viewModel.requestFocus()
            return
        }

        NSApp.activate(ignoringOtherApps: true)
        viewModel.prepareForPresentation()

        activeScreen = targetScreen()
        animationCoordinator.screen = activeScreen
        let height = viewModel.panelHeight
        panel.setFrame(
            PanelAnimationCoordinator.frame(for: activeScreen, height: height),
            display: true
        )
        animationCoordinator.prepareForPresentation(height: height)
        // The panel keeps alpha 1 after a completed fade-out; ordering it front
        // at full opacity would flash one frame before fadeIn reaches 0.
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        panel.invalidateShadow()
        animationCoordinator.fadeIn()
        viewModel.requestFocus()
    }

    func hide() {
        guard panel.isVisible, !animationCoordinator.isDismissalInProgress else { return }
        viewModel.dismissActionSheet()
        // 先启动淡出再收预览：还焦点回调看到 dismissal 进行中会自动跳过。
        animationCoordinator.fadeOutAndOrderOut()
        quickLook.close()
    }

    private func resizePanel(to height: CGFloat) {
        guard panel.isVisible else { return }

        animationCoordinator.screen = resolvedScreen()
        let target = PanelAnimationCoordinator.frame(
            for: animationCoordinator.screen,
            height: height
        )
        guard target.size != panel.frame.size || height != animationCoordinator.targetHeight else {
            if panel.frame.origin != target.origin {
                panel.setFrameOrigin(target.origin)
            }
            return
        }

        animationCoordinator.resize(toHeight: height)
    }

    private func targetScreen() -> NSScreen? {
        let mouseLocation = NSEvent.mouseLocation
        return NSScreen.screens.first(where: { screen in
            let frame = screen.frame
            return mouseLocation.x >= frame.minX && mouseLocation.x <= frame.maxX
                && mouseLocation.y >= frame.minY && mouseLocation.y <= frame.maxY
        })
            ?? panel.screen
            ?? NSScreen.main
            ?? NSScreen.screens.first
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

    func handleKeyDown(_ event: NSEvent) -> NSEvent? {
        guard panel.isVisible else { return event }

        if event.timestamp == lastHandledEventTimestamp && event.keyCode == lastHandledKeyCode {
            return nil
        }

        // When the focused field editor has marked text (e.g. active Pinyin/IME composition),
        // let the input method handle all keys: Return commits the composition, Escape aborts it,
        // and arrow keys browse candidate words.
        if hasActiveMarkedText {
            return event
        }

        switch event.keyCode {
        case UInt16(kVK_Escape):
            // Quick Look 打开时 Esc 只收起预览；动作菜单展开时 Esc 只收起菜单。
            if quickLook.isActive {
                quickLook.close()
            } else if viewModel.isActionSheetVisible {
                viewModel.dismissActionSheet()
            } else {
                handleEscape()
            }
            return markHandled(event)
        case UInt16(kVK_Return), UInt16(kVK_ANSI_KeypadEnter):
            // Cmd+Return searches the web via the default browser; plain Return opens the selection.
            if event.modifierFlags.contains(.command) {
                searchWebAndDismiss()
            } else if viewModel.isActionSheetVisible {
                // 菜单展开时独占回车；选中项暂不可用时也不穿透启动底层应用。
                if let action = viewModel.selectedAction,
                   let result = viewModel.selectedResult {
                    performMenuAction(action, for: result)
                }
            } else if let result = viewModel.selectedResult {
                open(result)
            }
            return markHandled(event)
        case UInt16(kVK_ANSI_F):
            guard event.modifierFlags.contains(.command) else { return event }
            if let result = viewModel.selectedResult {
                // Cmd+F reveals the item in Finder; quick queries copy their value instead.
                reveal(result)
            }
            return markHandled(event)
        case UInt16(kVK_ANSI_Y):
            guard event.modifierFlags.contains(.command) else { return event }
            // Cmd+Y toggles the native Quick Look preview of the selection.
            togglePreview()
            return markHandled(event)
        case UInt16(kVK_ANSI_K):
            guard event.modifierFlags.contains(.command) else { return event }
            // Cmd+K toggles the quick action menu of the selection.
            toggleActionMenu()
            return markHandled(event)
        case UInt16(kVK_ANSI_T):
            guard event.modifierFlags.contains(.command) else { return event }
            if let result = viewModel.selectedResult, result.terminalDirectory != nil {
                performMenuAction(.openInTerminal, for: result)
                return markHandled(event)
            }
            return event
        case UInt16(kVK_ANSI_B):
            guard event.modifierFlags.contains(.command) else { return event }
            if let result = viewModel.selectedResult,
               case .application(let app) = result,
               app.bundleIdentifier != nil {
                performMenuAction(.copyBundleID, for: result)
                return markHandled(event)
            }
            return event
        case UInt16(kVK_ANSI_C):
            if event.modifierFlags.contains(.command) && event.modifierFlags.contains(.option) {
                // Only file URLs have a meaningful path to copy; web URLs would lose the host.
                if let result = viewModel.selectedResult, result.url?.isFileURL == true {
                    performMenuAction(.copyPath, for: result)
                    return markHandled(event)
                }
            }
            return event
        case UInt16(kVK_UpArrow):
            if viewModel.isActionSheetVisible {
                viewModel.moveActionSelection(by: -1)
            } else {
                viewModel.moveSelection(by: -1)
                updateQuickLookPreviewForCurrentSelection()
            }
            return markHandled(event)
        case UInt16(kVK_DownArrow):
            if viewModel.isActionSheetVisible {
                viewModel.moveActionSelection(by: 1)
            } else {
                viewModel.moveSelection(by: 1)
                updateQuickLookPreviewForCurrentSelection()
            }
            return markHandled(event)
        default:
            return event
        }
    }

    @discardableResult
    private func markHandled(_ event: NSEvent) -> NSEvent? {
        lastHandledEventTimestamp = event.timestamp
        lastHandledKeyCode = event.keyCode
        return nil
    }

    func handleEscape() {
        if !viewModel.query.isEmpty {
            viewModel.query = ""
        } else {
            hide()
        }
    }

    @discardableResult
    func open(_ result: SearchResult) -> Task<Void, Never>? {
        if case .quickQuery(let quickQuery) = result {
            copy(quickQuery)
            return nil
        }
        guard let task = viewModel.open(result) else { return nil }
        return Task { [weak self] in
            await task.value
            guard let self else { return }
            if case .failed = self.viewModel.launchState {
                return
            }
            self.hide()
        }
    }

    /// Searches the current query in the default browser and dismisses the panel.
    @discardableResult
    func searchWebAndDismiss() -> Task<Void, Never>? {
        guard let task = viewModel.searchWeb() else { return nil }
        return Task { [weak self] in
            await task.value
            guard let self else { return }
            if case .failed = self.viewModel.launchState {
                return
            }
            self.hide()
        }
    }

    func reveal(_ result: SearchResult) {
        // Cmd+F 是唯一绕过 performMenuAction 的动作入口，无论后续隐藏面板、
        // 复制链接还是报错保留面板，都先退出菜单模式，避免卡片遮挡错误横幅。
        viewModel.dismissActionSheet()
        if case .quickQuery(let quickQuery) = result {
            copy(quickQuery)
            return
        }
        // Web URLs have no file-system location; reveal copies the link instead.
        if case .webURL(let url) = result {
            copyText(url.absoluteString)
            return
        }
        guard let url = result.url,
              FileManager.default.fileExists(atPath: url.path) else {
            viewModel.publishFileOpenError(
                fileName: result.name,
                reason: "文件已被移动或删除"
            )
            return
        }
        viewModel.reveal(result)
        hide()
    }

    /// Toggles the native Quick Look preview (`Cmd+Y`) of the selected result.
    private func togglePreview() {
        if quickLook.isActive {
            quickLook.close()
            return
        }
        // 预览与操作卡片互斥：开启预览前收起操作卡片。
        viewModel.dismissActionSheet()
        guard let result = viewModel.selectedResult else { return }
        // 网址与快速查询没有可预览的文件系统条目。
        guard let url = result.url, url.isFileURL else { return }
        guard FileManager.default.fileExists(atPath: url.path) else {
            viewModel.publishFileOpenError(
                fileName: result.name,
                reason: "文件已被移动或删除"
            )
            return
        }
        quickLook.show(url: url)
    }

    /// Updates the Quick Look preview item to follow selection changes (`↑` / `↓`).
    private func updateQuickLookPreviewForCurrentSelection() {
        guard quickLook.isActive else { return }
        guard let result = viewModel.selectedResult,
              let url = result.url,
              url.isFileURL,
              FileManager.default.fileExists(atPath: url.path) else {
            quickLook.reloadPreviewItem(with: nil)
            return
        }
        quickLook.reloadPreviewItem(with: url)
    }

    /// Toggles the quick action menu (`Cmd+K`).
    private func toggleActionMenu() {
        // 预览与操作卡片互斥：展开卡片前收起 Quick Look 预览。
        // 可用操作校验由 viewModel.toggleActionSheet() 内部完成，此处不重复判断。
        quickLook.close()
        viewModel.toggleActionSheet()
    }

    func performMenuAction(_ action: ResultMenuAction, for result: SearchResult) {
        viewModel.dismissActionSheet()
        switch action {
        case .revealInFinder:
            reveal(result)
        case .copyPath:
            guard let url = result.url else { return }
            copyText(url.path)
        case .copyBundleID:
            guard case .application(let app) = result, let bundleID = app.bundleIdentifier else { return }
            copyText(bundleID)
        case .openInTerminal:
            guard let directory = result.terminalDirectory else { return }
            guard FileManager.default.fileExists(atPath: directory.path) else {
                viewModel.publishFileOpenError(
                    fileName: result.name,
                    reason: "文件已被移动或删除"
                )
                return
            }
            viewModel.openInTerminal(url: directory)
            hide()
        }
    }

    private func copy(_ result: QuickQueryResult) {
        guard let value = result.copyValue else { return }
        copyText(value)
    }

    private func copyText(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
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
    /// Quick Look 预览会话，由 LauncherPanelController 持有并经响应链转发到这里。
    weak var quickLookPresenter: QuickLookPresenter?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func resignKey() {
        super.resignKey()
        onResignKey?()
    }

    /// QLPreviewPanel 经由 key 窗口的响应链寻找接管者（QLPreviewPanelController
    /// 分类方法）；启动器面板的键鼠处理都在窗口层，所以由窗口自身接管再委托给会话对象。
    /// 分类方法未标注隔离，QL 固定在主线程回调，这里显式断言回到主 actor。
    nonisolated override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool {
        MainActor.assumeIsolated { quickLookPresenter?.isActive ?? false }
    }

    nonisolated override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            guard let presenter = quickLookPresenter else { return }
            presenter.beginControl(in: panel)
        }
    }

    nonisolated override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated { quickLookPresenter?.endControl() }
    }
}
