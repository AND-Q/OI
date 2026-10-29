import AppKit
import Carbon.HIToolbox
import Combine
import Quartz
import SwiftUI

@MainActor
final class LauncherPanelController {
    private let viewModel: LauncherViewModel
    private let iconProvider: any IconProviding
    /// 复制路径、链接、回答等写入的剪贴板，测试传入独立的剪贴板以免覆盖系统剪贴板。
    /// 选中文字的 ⌘C 由文字控件自己写入系统剪贴板，不经这里。
    private let pasteboard: NSPasteboard
    let quickLook = QuickLookPresenter()
    let panel: LauncherPanel
    private let animationCoordinator: PanelAnimationCoordinator
    private var keyMonitor: Any?
    private var cancellables = Set<AnyCancellable>()
    private var activeScreen: NSScreen?
    private var lastHandledEventTimestamp: TimeInterval = 0
    private var lastHandledKeyCode: UInt16 = 0
    /// 「用其他 App 打开…」菜单项的响应者；菜单项只弱引用它，在此持有到下次弹出菜单。
    private var openWithMenuTarget: OpenWithMenuTarget?

    init(
        viewModel: LauncherViewModel,
        iconProvider: any IconProviding,
        pasteboard: NSPasteboard = .general
    ) {
        self.viewModel = viewModel
        self.iconProvider = iconProvider
        self.pasteboard = pasteboard

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
        // 只有 Quick AI 模式下能按住输入框以外的空白处（提问之后为标题栏）拖动（见 LauncherView），
        // 不随背景拖动，以免与选中回答冲突。
        panel.isMovable = true
        panel.isMovableByWindowBackground = false
        // Quick Look 经由响应链寻找接管者，接管点挂在窗口自身。
        panel.quickLookPresenter = quickLook

        animationCoordinator = PanelAnimationCoordinator(
            panel: panel,
            initialHeight: LauncherLayout.searchHeight
        )

        // 面板失去 key 窗口（点到桌面或其他应用）时收起，与原生聚焦搜索的默认行为一致。
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
            onDismiss: { [weak self] in self?.hide() },
            onCopy: { [weak self] text in self?.writeToPasteboard(text) }
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

        // 窗口随 SwiftUI 布局同步伸缩。
        viewModel.$panelHeight
            .sink { [weak self] height in
                self?.resizePanel(to: height)
            }
            .store(in: &cancellables)

        // 用户切换到其他应用时收起。
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
        // 淡出途中改走 show()：此时 hide() 会丢掉这次请求，按下的快捷键被吞掉。
        (isVisible && !animationCoordinator.isDismissalInProgress) ? hide() : show()
    }

    func show() {
        guard !panel.isVisible else {
            // 已经显示：重新聚焦，不重置会话。先撤销进行中的淡出，
            // 否则淡出完成时会在这次唤起后立即把面板移出屏幕。
            NSApp.activate(ignoringOtherApps: true)
            animationCoordinator.cancelDismissal()
            activeScreen = targetScreen()
            animationCoordinator.screen = activeScreen
            animationCoordinator.moveToDefaultPosition(height: animationCoordinator.currentHeight)
            panel.makeKeyAndOrderFront(nil)
            viewModel.requestFocus()
            return
        }

        NSApp.activate(ignoringOtherApps: true)
        viewModel.prepareForPresentation()

        activeScreen = targetScreen()
        animationCoordinator.screen = activeScreen
        let height = viewModel.panelHeight
        animationCoordinator.moveToDefaultPosition(height: height)
        animationCoordinator.prepareForPresentation(height: height)
        // 淡出完成后面板的透明度保持为 1；以完全不透明的状态移到最前，
        // 会在 fadeIn 把透明度降到 0 之前闪现一帧。
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        panel.invalidateShadow()
        animationCoordinator.fadeIn()
        viewModel.requestFocus()
    }

    func hide() {
        guard panel.isVisible, !animationCoordinator.isDismissalInProgress else { return }
        viewModel.dismissActionSheet()
        // 只中断请求、保留已收到的回答，避免淡出途中面板高度收缩。
        viewModel.stopQuickAI()
        // 先启动淡出再收预览：还焦点回调看到 dismissal 进行中会自动跳过。
        animationCoordinator.fadeOutAndOrderOut()
        quickLook.close()
    }

    private func resizePanel(to height: CGFloat) {
        guard panel.isVisible else { return }

        animationCoordinator.screen = resolvedScreen()
        let target = animationCoordinator.frame(forHeight: height)
        guard target.size != panel.frame.size || height != animationCoordinator.targetHeight else {
            if panel.frame.origin != target.origin {
                animationCoordinator.setPanelFrame(target, display: false)
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

    /// 沿用 show() 时选定的屏幕，会话期间面板不会跳到其他显示器；只有该显示器已断开时才重新选择。
    private func resolvedScreen() -> NSScreen? {
        if let activeScreen, NSScreen.screens.contains(activeScreen) {
            return activeScreen
        }
        activeScreen = targetScreen()
        return activeScreen
    }

    func handleKeyDown(_ event: NSEvent) -> NSEvent? {
        guard panel.isVisible else { return event }

        // 回车打开后面板随即淡出：淡出期间不再响应面板内的按键，避免手快连按回车重复打开，
        // 或把字符打进正在消失的输入框。
        if animationCoordinator.isDismissalInProgress, event.window === panel {
            return nil
        }

        if event.timestamp == lastHandledEventTimestamp && event.keyCode == lastHandledKeyCode {
            return nil
        }

        // 输入框的字段编辑器有未上屏的组字（如拼音输入法正在组字）时，所有按键交给输入法：
        // 回车上屏、Esc 取消组字、方向键浏览候选词。
        if hasActiveMarkedText {
            return event
        }

        switch event.keyCode {
        case UInt16(kVK_Escape):
            handleEscapeKey()
            return markHandled(event)
        case UInt16(kVK_Tab):
            // Tab 在检索与 Quick AI 模式间切换，已输入的文字保留；带修饰键时保持系统默认行为。
            guard event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty else {
                return event
            }
            viewModel.toggleQuickAIMode()
            // 预览与回答区互斥：进入 Quick AI 前收起 Quick Look 预览。
            quickLook.close()
            return markHandled(event)
        case UInt16(kVK_Return), UInt16(kVK_ANSI_KeypadEnter):
            handleReturnKey(isCommandPressed: event.modifierFlags.contains(.command))
            return markHandled(event)
        case UInt16(kVK_ANSI_F):
            guard event.modifierFlags.contains(.command) else { return event }
            if let result = viewModel.selectedResult {
                // Cmd+F 在 Finder 中显示条目；快速查询改为复制其值。
                reveal(result)
            }
            return markHandled(event)
        case UInt16(kVK_ANSI_Y):
            guard event.modifierFlags.contains(.command) else { return event }
            // Cmd+Y 开关选中项的原生 Quick Look 预览。
            togglePreview()
            return markHandled(event)
        case UInt16(kVK_ANSI_K):
            guard event.modifierFlags.contains(.command) else { return event }
            // Cmd+K 开关选中项的快捷操作菜单。
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
            return handleCopyKey(event)
        case UInt16(kVK_UpArrow):
            handleVerticalArrowKey(by: -1)
            return markHandled(event)
        case UInt16(kVK_DownArrow):
            handleVerticalArrowKey(by: 1)
            return markHandled(event)
        default:
            // 在回答区点选文字后焦点离开了输入框：继续打字时先把焦点交回输入框，按键照常输入。
            if viewModel.quickAISession != nil,
               !event.modifierFlags.contains(.command),
               !isSearchFieldFocused {
                focusSearchFieldAtEnd()
            }
            return event
        }
    }

    /// Esc 分级关闭：Quick Look 打开时 Esc 只收起预览；动作菜单展开时 Esc 只收起菜单。
    private func handleEscapeKey() {
        if quickLook.isActive {
            quickLook.close()
        } else if viewModel.isActionSheetVisible {
            viewModel.dismissActionSheet()
        } else if viewModel.quickAISession != nil {
            // 已提问：Esc 一次即中断回答并关闭面板。
            hide()
        } else if viewModel.isQuickAIModeActive {
            // 尚未提问：Esc 返回检索，已输入的文字保留。
            viewModel.toggleQuickAIMode()
        } else {
            handleEscape()
        }
    }

    /// Cmd+Return 在默认浏览器中网页搜索；单独的 Return 打开选中项。
    private func handleReturnKey(isCommandPressed: Bool) {
        if isCommandPressed {
            searchWebAndDismiss()
        } else if viewModel.isQuickAIModeActive {
            // 尚未提问时 Enter 发起提问；已有对话时输入框有文字即追问，否则复制最后一条回答并关闭或重试这一轮，
            // 输出期间不响应。
            if let returnAction = viewModel.quickAIReturnAction {
                switch returnAction {
                case .followUp:
                    viewModel.startQuickAI()
                case .copyAndClose:
                    if let answer = viewModel.quickAIAnswerToCopy {
                        copyText(answer)
                    }
                case .retry:
                    viewModel.retryQuickAI()
                case .none:
                    break
                }
            } else {
                viewModel.startQuickAI()
            }
        } else if viewModel.isActionSheetVisible {
            // 菜单展开时独占回车；选中项暂不可用时也不穿透启动底层应用。
            if let action = viewModel.selectedAction,
               let result = viewModel.selectedResult {
                performMenuAction(action, for: result)
            }
        } else if let result = viewModel.selectedResult {
            open(result)
        }
    }

    /// Quick AI 中的 Cmd+C 与复制路径的 Cmd+Option+C；其余组合交还给系统。
    private func handleCopyKey(_ event: NSEvent) -> NSEvent? {
        if viewModel.quickAISession != nil,
           event.modifierFlags.contains(.command),
           !event.modifierFlags.contains(.option) {
            // Quick AI 中 Cmd+C 优先复制选中的文字（输入框或回答区）；都没有选中时复制最后一条回答
            // 并保留面板，流式输出期间复制当前已到达的部分。
            if isSearchFieldFocused {
                // 输入框选区直接交给系统复制；按选区长度判断，不依赖空选区时 copy: 的行为。
                if let editor = panel.firstResponder as? NSTextView, editor.selectedRange().length > 0 {
                    return event
                }
            } else if copySelectionFromFirstResponder() {
                viewModel.markQuickAIAnswerCopied()
                return markHandled(event)
            }
            if let answer = viewModel.quickAIAnswerToCopy {
                writeToPasteboard(answer)
                viewModel.markQuickAIAnswerCopied()
            }
            return markHandled(event)
        }
        if event.modifierFlags.contains(.command) && event.modifierFlags.contains(.option) {
            // 只有文件地址的路径值得复制；网址只取路径会丢掉主机名。
            if let result = viewModel.selectedResult, result.url?.isFileURL == true {
                performMenuAction(.copyPath, for: result)
                return markHandled(event)
            }
        }
        return event
    }

    /// `↑` / `↓`：操作菜单展开时移动菜单选择，有回答时滚动回答区，否则移动结果选择（预览随之跟随）。
    private func handleVerticalArrowKey(by offset: Int) {
        if viewModel.isActionSheetVisible {
            viewModel.moveActionSelection(by: offset)
        } else if viewModel.quickAISession != nil {
            viewModel.scrollQuickAIAnswer(by: offset)
        } else {
            viewModel.moveSelection(by: offset)
            updateQuickLookPreviewForCurrentSelection()
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

    /// 打开选中项后立即收起面板，不等目标应用启动完成（冷启动可能要数秒，面板会一直停留）；
    /// 打开失败由视图模型经系统通知告知。面板已收起或正在淡出时不再响应，避免连击重复打开。
    /// 返回在后台进行的打开任务。
    @discardableResult
    func open(_ result: SearchResult) -> Task<Void, Never>? {
        guard panel.isVisible, !animationCoordinator.isDismissalInProgress else { return nil }
        if case .quickQuery(let quickQuery) = result {
            copy(quickQuery)
            return nil
        }
        guard let task = viewModel.open(result) else { return nil }
        hide()
        return task
    }

    /// 在默认浏览器中搜索当前输入，并立即收起面板。
    @discardableResult
    func searchWebAndDismiss() -> Task<Void, Never>? {
        guard let task = viewModel.searchWeb() else { return nil }
        hide()
        return task
    }

    func reveal(_ result: SearchResult) {
        // Cmd+F 是唯一绕过 performMenuAction 的动作入口，无论后续隐藏面板、
        // 复制链接还是报错保留面板，都先退出菜单模式，避免卡片遮挡错误横幅。
        viewModel.dismissActionSheet()
        if case .quickQuery(let quickQuery) = result {
            copy(quickQuery)
            return
        }
        // 网址没有文件系统位置，改为复制链接。
        if case .webURL(let url) = result {
            copyText(url.absoluteString)
            return
        }
        guard let url = result.url,
              FileManager.default.fileExists(atPath: url.path) else {
            viewModel.publishFileOpenError(
                fileName: result.name,
                reason: String(localized: "文件已被移动或删除")
            )
            return
        }
        viewModel.reveal(result)
        hide()
    }

    /// 开关选中结果的原生 Quick Look 预览（`Cmd+Y`）。
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
                reason: String(localized: "文件已被移动或删除")
            )
            return
        }
        quickLook.show(url: url)
    }

    /// 选中项变化（`↑` / `↓`）时让 Quick Look 预览跟随。
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

    /// 开关快捷操作菜单（`Cmd+K`）。
    private func toggleActionMenu() {
        // 预览与操作卡片互斥：展开卡片前收起 Quick Look 预览。
        // 可用操作校验由 viewModel.toggleActionSheet() 内部完成，此处不重复判断。
        quickLook.close()
        viewModel.toggleActionSheet()
    }

    func performMenuAction(_ action: ResultMenuAction, for result: SearchResult) {
        // 「用其他 App 打开…」先保留卡片、在卡片下方弹出 App 菜单，取消时回到卡片改选其他操作。
        if action != .openWith {
            viewModel.dismissActionSheet()
        }
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
                    reason: String(localized: "文件已被移动或删除")
                )
                return
            }
            viewModel.openInTerminal(url: directory)
            hide()
        case .openWith:
            guard case .file(let file) = result else { return }
            guard FileManager.default.fileExists(atPath: file.url.path) else {
                viewModel.dismissActionSheet()
                viewModel.publishFileOpenError(
                    fileName: result.name,
                    reason: String(localized: "文件已被移动或删除")
                )
                return
            }
            showOpenWithMenu(for: file)
        }
    }

    /// 弹出系统菜单列出能打开该文件的 App，与 Finder 的「打开方式」相同：默认 App 在前并标注，
    /// 其余按名称排序。选中即用该 App 打开并收起面板。
    private func showOpenWithMenu(for file: FileDescriptor) {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(.sectionHeader(title: String(localized: "用其他 App 打开")))
        let applications = viewModel.applications(toOpen: file)
        let target = OpenWithMenuTarget { [weak self] applicationURL in
            guard let self else { return }
            self.viewModel.dismissActionSheet()
            self.viewModel.open(file, withApplicationAt: applicationURL)
            self.hide()
        }
        openWithMenuTarget = target
        for application in applications {
            let item = NSMenuItem(
                title: application.isDefault ? String(localized: "\(application.name)（默认）") : application.name,
                action: #selector(OpenWithMenuTarget.chooseApplication(_:)),
                keyEquivalent: ""
            )
            item.target = target
            item.representedObject = application.url
            item.image = menuIcon(for: application.url)
            menu.addItem(item)
            if application.isDefault, applications.count > 1 {
                menu.addItem(.separator())
            }
        }
        if applications.isEmpty {
            let item = NSMenuItem(title: String(localized: "没有可以打开它的 App"), action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
        // 菜单左上角对齐操作卡片的左下角（屏幕坐标），像从卡片下方展开。
        let location = NSPoint(
            x: panel.frame.maxX - LauncherLayout.actionSheetTrailingInset - LauncherLayout.actionSheetWidth,
            y: panel.frame.minY + LauncherLayout.actionSheetBottomInset
        )
        menu.popUp(positioning: nil, at: location, in: nil)
    }

    /// 菜单项使用的小图标；图标提供者返回的是缓存中的共享实例，改尺寸前先复制一份。
    private func menuIcon(for applicationURL: URL) -> NSImage? {
        let icon = iconProvider.icon(for: applicationURL).copy() as? NSImage
        icon?.size = NSSize(width: 16, height: 16)
        return icon
    }

    private func copy(_ result: QuickQueryResult) {
        guard let value = result.copyValue else { return }
        copyText(value)
    }

    private func copyText(_ value: String) {
        writeToPasteboard(value)
        hide()
    }

    private func writeToPasteboard(_ value: String) {
        pasteboard.clearContents()
        pasteboard.setString(value, forType: .string)
    }

    /// 面板里同时只有一个文本输入（顶部的检索框，或 Quick AI 提问之后对话下方的追问框），
    /// 字段编辑器为第一响应者即表示焦点在输入框。
    private var isSearchFieldFocused: Bool {
        (panel.firstResponder as? NSTextView)?.isFieldEditor == true
    }

    /// 让第一响应者（回答区的可选中文字）执行复制；剪贴板有变化才算复制成功。
    private func copySelectionFromFirstResponder() -> Bool {
        let changeCount = NSPasteboard.general.changeCount
        NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: panel)
        return NSPasteboard.general.changeCount != changeCount
    }

    /// 焦点交回输入框（检索框或追问框）并把光标放到末尾，避免默认全选后下一个按键覆盖整个问题。
    private func focusSearchFieldAtEnd() {
        guard let input = panel.contentView?.firstDescendant(of: LauncherSearchInputView.self) else { return }
        panel.makeFirstResponder(input.textField)
        let end = (input.textField.stringValue as NSString).length
        input.textField.currentEditor()?.selectedRange = NSRange(location: end, length: 0)
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

/// 「用其他 App 打开…」菜单项的响应者：选中某个 App 时回调该 App 的地址。
@MainActor
private final class OpenWithMenuTarget: NSObject {
    private let onSelect: (URL) -> Void

    init(onSelect: @escaping (URL) -> Void) {
        self.onSelect = onSelect
    }

    @objc func chooseApplication(_ sender: NSMenuItem) {
        guard let applicationURL = sender.representedObject as? URL else { return }
        onSelect(applicationURL)
    }
}

final class LauncherPanel: NSPanel {
    /// 面板失去 key 窗口状态时调用。
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

private extension NSView {
    func firstDescendant<T: NSView>(of type: T.Type) -> T? {
        for subview in subviews {
            if let match = subview as? T ?? subview.firstDescendant(of: type) {
                return match
            }
        }
        return nil
    }
}
