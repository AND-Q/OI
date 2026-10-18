import AppKit
import Carbon.HIToolbox
import os

/// 划词翻译气泡的管理：每次翻译弹出「当前气泡」（`TranslatorBubble`），点到其他应用、`Esc` 或再按快捷键即收起；
/// 点按气泡右上角的图钉后，这个气泡固定在屏幕上，与之后的翻译互相隔离——点到别处、切换应用、退出框选都不收起，
/// 只由它自己的关闭按钮、`Esc` 或回车复制关闭；之后的翻译另开新的当前气泡。可以同时固定多个。
/// 截图翻译时先进入框选（`ScreenSelectionOverlay`），框选完成后当前气泡贴着选框弹出、显示在遮罩之上。
@MainActor
final class TranslatorPanelController {
    /// 当前气泡收起的原因，记入日志以便排查气泡意外收起。
    private enum DismissReason: String {
        case lostKeyFocus = "lost key focus"
        case clickOutside = "click outside"
        case escapeKey = "escape key"
        case returnKey = "return key"
        case shortcut = "shortcut"
        /// 截图翻译中开始拖出新的选框：只收起气泡，框选继续。
        case reselect = "reselect"
        /// 截图翻译中右键或有其他应用切到前台：退出框选。
        case selectionCancelled = "selection cancelled"
        /// 左上角的关闭按钮：只关闭气泡，截图翻译的框选继续。
        case closeButton = "close button"
        /// ⌘W：同关闭按钮。
        case closeShortcut = "command-W"
    }

    private let makeViewModel: @MainActor () -> TranslatorViewModel
    /// 跟随每次翻译弹出的气泡。
    private var current: TranslatorBubble
    /// 已固定的气泡，各自关闭后移除。
    private var pinnedBubbles: [TranslatorBubble] = []
    private let selectionOverlay = ScreenSelectionOverlay()
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "OI", category: "Translator")
    private var keyMonitor: Any?
    private var clickMonitor: Any?

    /// `makeViewModel` 为每个气泡新建一份翻译状态：固定的气泡保留自己的内容，与之后的翻译互不影响。
    init(makeViewModel: @escaping @MainActor () -> TranslatorViewModel) {
        self.makeViewModel = makeViewModel
        current = TranslatorBubble(viewModel: makeViewModel())
        configureCurrent()
        selectionOverlay.onSelectionStart = { [weak self] in self?.hide(reason: .reselect) }
        selectionOverlay.onSelection = { [weak self] rect in self?.translateScreenRegion(rect) }
        selectionOverlay.onCancel = { [weak self] in self?.hide(reason: .selectionCancelled) }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return self.handleKeyDown(event)
        }
    }

    isolated deinit {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
        }
        if let clickMonitor {
            NSEvent.removeMonitor(clickMonitor)
        }
    }

    /// 当前气泡是否显示中（不含固定的气泡）。
    var isVisible: Bool { current.isVisible }

    /// 翻译快捷键：当前气泡已显示时收起，否则翻译选中的文字或剪贴板。
    func toggleShortcutTranslation() {
        if isVisible {
            hide(reason: .shortcut)
            return
        }
        let bubble = current
        Task { [weak self] in
            guard let presentation = await bubble.viewModel.captureFromShortcut(),
                  let self, bubble === self.current else { return }
            self.present(presentation, pointer: nil)
        }
    }

    /// 触控板用力点按：翻译该处的单词；该处不是文字时什么也不做。
    func translateText(at point: CGPoint) {
        let bubble = current
        Task { [weak self] in
            guard let presentation = await bubble.viewModel.captureFromForceTouch(at: point),
                  let self, bubble === self.current else { return }
            self.present(presentation, pointer: point)
        }
    }

    /// 截图翻译快捷键：进入框选，框选中再按则退出；未获屏幕录制权限时只弹出说明与授权入口。
    func toggleScreenTranslation() {
        if selectionOverlay.isActive {
            hide(reason: .shortcut)
            return
        }
        if isVisible {
            hide(reason: .shortcut)
        }
        guard current.viewModel.beginScreenTranslation() else {
            present(TranslatorPresentation(anchorRect: nil), pointer: nil)
            return
        }
        selectionOverlay.begin()
    }

    func stop() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        endSelection()
        removeClickMonitor()
        current.stop()
        for bubble in pinnedBubbles {
            bubble.stop()
        }
        pinnedBubbles.removeAll()
    }

    private func translateScreenRegion(_ rect: CGRect) {
        present(current.viewModel.translateScreenRegion(rect), pointer: nil)
    }

    // MARK: - Current bubble

    private func configureCurrent() {
        current.onClose = { [weak self] in self?.hide(reason: .closeButton) }
        current.onPin = { [weak self] in self?.pinCurrent() }
        // 点到其他应用（包括原应用）或其他气泡时面板失去 key，气泡随之收起。
        current.onResignKey = { [weak self] in self?.hide(reason: .lostKeyFocus) }
        current.onHidden = nil
    }

    /// `pointer` 为用力点按位置（全局显示坐标）；快捷键触发时为 nil，取当前鼠标位置。
    private func present(_ presentation: TranslatorPresentation, pointer: CGPoint?) {
        current.present(presentation, pointer: pointer, level: bubbleLevel)
        installClickMonitor()
    }

    /// 截图翻译框选期间，气泡与高亮显示在遮罩之上。
    private var bubbleLevel: NSWindow.Level {
        selectionOverlay.isActive
            ? NSWindow.Level(rawValue: ScreenSelectionOverlay.level.rawValue + 1)
            : .floating
    }

    private func hide(reason: DismissReason) {
        if selectionOverlay.isActive {
            switch reason {
            case .lostKeyFocus:
                // 框选期间点按遮罩会让气泡失去 key：气泡保留，按键改由遮罩接收。
                return
            case .reselect, .closeButton, .closeShortcut:
                break
            case .clickOutside, .escapeKey, .returnKey, .shortcut, .selectionCancelled:
                endSelection()
            }
        }
        guard current.isVisible else { return }
        logger.debug("Translator bubble hidden: \(reason.rawValue, privacy: .public)")
        removeClickMonitor()
        current.hide()
    }

    /// 退出框选：固定的气泡留在屏幕上，从遮罩之上降回普通浮动层级。
    private func endSelection() {
        selectionOverlay.end()
        for bubble in pinnedBubbles {
            bubble.setLevel(.floating)
        }
    }

    // MARK: - Pinned bubbles

    /// 固定当前气泡：同一个窗口与翻译状态移入固定的一组，进行中的翻译或识别不中断；之后的翻译另开新的当前气泡。
    /// 只有提示的气泡不能固定。
    private func pinCurrent() {
        let bubble = current
        guard bubble.isVisible, bubble.viewModel.session != nil else { return }
        logger.debug("Translator bubble pinned")
        removeClickMonitor()
        bubble.removeHighlight()
        bubble.viewModel.isPinned = true
        bubble.onPin = nil
        bubble.onResignKey = nil
        bubble.onClose = { [weak bubble] in bubble?.hide() }
        bubble.onHidden = { [weak self, weak bubble] in
            self?.pinnedBubbles.removeAll { $0 === bubble }
        }
        pinnedBubbles.append(bubble)
        current = TranslatorBubble(viewModel: makeViewModel())
        configureCurrent()
    }

    private func pinnedBubble(for window: NSWindow?) -> TranslatorBubble? {
        pinnedBubbles.first { $0.panel === window && $0.isVisible }
    }

    // MARK: - Monitors

    /// 全局监听只会收到发往其他应用的点击，即 OI 窗口之外的点击。
    private func installClickMonitor() {
        guard clickMonitor == nil else { return }
        clickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            self?.hide(reason: .clickOutside)
        }
    }

    private func removeClickMonitor() {
        if let clickMonitor {
            NSEvent.removeMonitor(clickMonitor)
        }
        clickMonitor = nil
    }

    // MARK: - Keyboard

    private func handleKeyDown(_ event: NSEvent) -> NSEvent? {
        // 按键发给所在窗口对应的气泡：固定的气泡只处理自己的按键，Esc 只关闭它自己；
        // 截图翻译框选期间按键也可能发往遮罩（尚未弹出气泡，或点按遮罩后遮罩成为 key），按当前气泡的规则处理。
        let bubble: TranslatorBubble
        if let pinned = pinnedBubble(for: event.window) {
            bubble = pinned
        } else if (event.window === current.panel && current.isVisible) || selectionOverlay.contains(event.window) {
            bubble = current
        } else {
            return event
        }
        // 输入法组字期间回车上屏、Esc 取消组字，都交给输入法。
        if (bubble.panel.firstResponder as? NSTextInputClient)?.hasMarkedText() == true {
            return event
        }

        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        switch Int(event.keyCode) {
        case kVK_Escape:
            close(bubble, reason: .escapeKey)
            return nil
        case kVK_Return, kVK_ANSI_KeypadEnter:
            // 带修饰键的回车（如 ⌥↩ 换行）交给原文输入框。
            guard modifiers.isEmpty else { return event }
            performReturn(in: bubble)
            return nil
        default:
            guard modifiers == .command, let key = event.charactersIgnoringModifiers?.lowercased() else {
                return event
            }
            return handleCommandKey(key, event: event, in: bubble)
        }
    }

    /// 当前气泡按收起规则处理；固定的气泡直接关闭它自己。
    private func close(_ bubble: TranslatorBubble, reason: DismissReason) {
        if bubble === current {
            hide(reason: reason)
        } else {
            bubble.hide()
        }
    }

    private func performReturn(in bubble: TranslatorBubble) {
        let viewModel = bubble.viewModel
        guard let session = viewModel.session else {
            // 只有提示时回车即关闭。
            close(bubble, reason: .returnKey)
            return
        }
        switch session.returnAction {
        case .translate, .retry:
            viewModel.translateCurrentSource()
        case .copyAndClose:
            if let translation = viewModel.translationToCopy {
                writeToPasteboard(translation)
                close(bubble, reason: .returnKey)
            }
        case .none:
            break
        }
    }

    /// OI 没有可见的主菜单、气泡出现时也不激活 OI，编辑快捷键在这里直接分派给第一响应者，⌘W 在这里关闭气泡。
    private func handleCommandKey(_ key: String, event: NSEvent, in bubble: TranslatorBubble) -> NSEvent? {
        let panel = bubble.panel
        let viewModel = bubble.viewModel
        switch key {
        case "w":
            // 同左上角的关闭按钮；不处理时会交给主菜单的「关闭」，无边框的气泡关不掉，只会提示音。
            close(bubble, reason: .closeShortcut)
            return nil
        case "c":
            // 选中了部分原文或译文时复制选中的部分；都没有选中时复制整段译文并保留气泡。
            if let editor = panel.firstResponder as? NSTextView, editor.isFieldEditor {
                if editor.selectedRange().length > 0 {
                    editor.copy(nil)
                    return nil
                }
            } else if copySelectionFromFirstResponder(of: panel) {
                viewModel.markCopied()
                return nil
            }
            if let translation = viewModel.translationToCopy {
                writeToPasteboard(translation)
                viewModel.markCopied()
            }
            return nil
        case "a", "x", "v":
            let action = switch key {
            case "a": #selector(NSText.selectAll(_:))
            case "x": #selector(NSText.cut(_:))
            default: #selector(NSText.paste(_:))
            }
            return NSApp.sendAction(action, to: nil, from: panel) ? nil : event
        default:
            return event
        }
    }

    /// 让第一响应者（译文的可选中文字）执行复制；剪贴板有变化才算复制成功。
    private func copySelectionFromFirstResponder(of panel: NSPanel) -> Bool {
        let changeCount = NSPasteboard.general.changeCount
        NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: panel)
        return NSPasteboard.general.changeCount != changeCount
    }

    private func writeToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// 气泡相对原文的摆放（AppKit 屏幕坐标，原点在主屏左下角）：优先放在原文下方，下方放不下时放到上方；
/// 原文区域很高（如跨多行的长选区）、两侧都放不下时改为贴着指针。摆放方向在弹出时确定，
/// 之后译文增长只沿该方向伸长，不会中途翻转。
struct TranslatorPlacement: Equatable {
    enum Edge: Equatable {
        /// 气泡在锚点下方，顶边固定，内容增长时向下伸长。
        case below(top: CGFloat)
        /// 气泡在锚点上方，底边固定，内容增长时向上伸长。
        case above(bottom: CGFloat)
    }

    /// 气泡与原文之间的间距。
    static let gap: CGFloat = 6
    /// 与屏幕可见区域边缘保持的最小距离。
    static let margin: CGFloat = 8

    let x: CGFloat
    let edge: Edge
    let width: CGFloat
    let visibleFrame: NSRect

    init(anchor: NSRect, pointer: NSPoint, visibleFrame: NSRect, width: CGFloat, expectedHeight: CGFloat) {
        self.width = width
        self.visibleFrame = visibleFrame
        let spaceBelow = anchor.minY - Self.gap - (visibleFrame.minY + Self.margin)
        let spaceAbove = (visibleFrame.maxY - Self.margin) - (anchor.maxY + Self.gap)
        let pointerAnchor = Self.pointerAnchor(at: pointer)

        let chosenAnchor: NSRect
        if spaceBelow >= expectedHeight {
            chosenAnchor = anchor
            edge = .below(top: anchor.minY - Self.gap)
        } else if spaceAbove >= expectedHeight {
            chosenAnchor = anchor
            edge = .above(bottom: anchor.maxY + Self.gap)
        } else if anchor.height > pointerAnchor.height * 2 {
            chosenAnchor = pointerAnchor
            let pointerSpaceBelow = pointerAnchor.minY - Self.gap - (visibleFrame.minY + Self.margin)
            let pointerSpaceAbove = (visibleFrame.maxY - Self.margin) - (pointerAnchor.maxY + Self.gap)
            edge = pointerSpaceBelow >= min(expectedHeight, pointerSpaceAbove)
                ? .below(top: pointerAnchor.minY - Self.gap)
                : .above(bottom: pointerAnchor.maxY + Self.gap)
        } else {
            chosenAnchor = anchor
            edge = spaceBelow >= spaceAbove
                ? .below(top: anchor.minY - Self.gap)
                : .above(bottom: anchor.maxY + Self.gap)
        }

        let minX = visibleFrame.minX + Self.margin
        let maxX = max(visibleFrame.maxX - Self.margin - width, minX)
        x = min(max(chosenAnchor.minX, minX), maxX)
    }

    /// 被拖动过的气泡：左上角固定在当前位置，内容增长时向下伸长；水平方向保持用户放下的位置。
    init(keepingTopLeftOf frame: NSRect, visibleFrame: NSRect) {
        width = frame.width
        self.visibleFrame = visibleFrame
        x = frame.minX
        edge = .below(top: frame.maxY)
    }

    /// 给定内容高度时的窗口位置：沿摆放方向伸长，并限制在屏幕可见区域内。
    func frame(height: CGFloat) -> NSRect {
        let height = min(height, visibleFrame.height - Self.margin * 2)
        let y: CGFloat = switch edge {
        case .below(let top): top - height
        case .above(let bottom): bottom
        }
        let minY = visibleFrame.minY + Self.margin
        let maxY = visibleFrame.maxY - Self.margin - height
        return NSRect(
            x: x.rounded(),
            y: min(max(y, minY), maxY).rounded(),
            width: width,
            height: height.rounded()
        )
    }

    /// 没有文字位置时以指针为锚点：一行文字高，气泡左缘略在指针左侧。
    static func pointerAnchor(at point: NSPoint) -> NSRect {
        NSRect(x: point.x - 24, y: point.y - 10, width: 1, height: 20)
    }

    /// 全局显示坐标（原点在主屏左上角、y 轴向下）转为 AppKit 屏幕坐标（原点在主屏左下角、y 轴向上）。
    static func appKitRect(fromGlobal rect: CGRect, primaryScreenHeight: CGFloat) -> NSRect {
        NSRect(x: rect.minX, y: primaryScreenHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    static func appKitPoint(fromGlobal point: CGPoint, primaryScreenHeight: CGFloat) -> NSPoint {
        NSPoint(x: point.x, y: primaryScreenHeight - point.y)
    }

    /// AppKit 屏幕坐标转为全局显示坐标，`appKitRect(fromGlobal:primaryScreenHeight:)` 的逆变换。
    static func globalRect(fromAppKit rect: NSRect, primaryScreenHeight: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: primaryScreenHeight - rect.maxY, width: rect.width, height: rect.height)
    }
}

final class TranslatorPanel: NSPanel {
    /// Invoked when the panel loses key window status.
    var onResignKey: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func resignKey() {
        super.resignKey()
        onResignKey?()
    }
}

/// 气泡的玻璃表面：用统一的圆角轮廓裁剪整个玻璃层，窗口阴影仍由系统按轮廓绘制。
final class TranslatorPanelSurface: NSView {
    private let glassView = NSGlassEffectView()

    init(contentView: NSView, cornerRadius: CGFloat) {
        super.init(frame: contentView.frame)
        wantsLayer = true
        layer?.cornerRadius = cornerRadius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true

        glassView.frame = bounds
        glassView.autoresizingMask = [.width, .height]
        glassView.style = .regular
        glassView.cornerRadius = cornerRadius
        contentView.frame = glassView.bounds
        contentView.autoresizingMask = [.width, .height]
        glassView.contentView = contentView
        addSubview(glassView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

/// 盖在原文单词上的黄色高亮，仿照系统「查询」：半透明以透出下面的文字，
/// 在 `updateLayer` 中取色，浅色与深色外观切换时随之更新。
final class TranslatorHighlightView: NSView {
    private static let cornerRadius: CGFloat = 4
    private static let opacity: CGFloat = 0.4

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.systemYellow.withAlphaComponent(Self.opacity).cgColor
        layer?.cornerRadius = Self.cornerRadius
        layer?.cornerCurve = .continuous
    }
}
