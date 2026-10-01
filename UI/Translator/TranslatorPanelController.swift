import AppKit
import Carbon.HIToolbox
import SwiftUI

/// 划词翻译气泡的 AppKit 壳：不激活 OI 的浮动面板，弹在原文旁边。
/// 面板成为 key 窗口以接收 Esc / 回车与原文编辑，但 OI 不切到前台，原应用保持激活。
@MainActor
final class TranslatorPanelController {
    private enum Layout {
        static let fadeInDuration: TimeInterval = 0.12
        static let fadeOutDuration: TimeInterval = 0.15
        /// 首次排版完成前的估计高度。
        static let initialHeight: CGFloat = 120
    }

    private let viewModel: TranslatorViewModel
    let panel: TranslatorPanel
    private var keyMonitor: Any?
    private var clickMonitor: Any?
    private var placement: TranslatorPlacement?
    private var contentHeight = Layout.initialHeight
    /// 每次弹出递增：淡出完成时据此判断期间是否又弹出了新的气泡。
    private var presentationGeneration = 0
    private var isDismissing = false

    init(viewModel: TranslatorViewModel) {
        self.viewModel = viewModel
        panel = TranslatorPanel(
            contentRect: NSRect(x: 0, y: 0, width: TranslatorLayout.width, height: Layout.initialHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.isMovable = false
        panel.animationBehavior = .none

        let hostingView = NSHostingView(
            rootView: TranslatorView(viewModel: viewModel) { [weak self] height in
                self?.updateContentHeight(height)
            }
        )
        // 窗口高度由内容上报的自然高度驱动，不让托管视图的固有尺寸约束反过来牵制窗口。
        hostingView.sizingOptions = []
        hostingView.autoresizingMask = [.width, .height]
        panel.contentView = TranslatorPanelSurface(
            contentView: hostingView,
            cornerRadius: TranslatorLayout.cornerRadius
        )

        // 点到其他应用（包括原应用）时面板失去 key，气泡随之收起。
        panel.onResignKey = { [weak self] in self?.hide() }
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

    var isVisible: Bool { panel.isVisible && !isDismissing }

    /// 翻译快捷键：气泡已显示时收起，否则翻译选中的文字或剪贴板。
    func toggleShortcutTranslation() {
        if isVisible {
            hide()
            return
        }
        Task { [weak self] in
            guard let self, let presentation = await self.viewModel.captureFromShortcut() else { return }
            self.present(presentation, pointer: nil)
        }
    }

    /// 触控板用力点按：翻译该处的选中文字或单词；该处不是文字时什么也不做。
    func translateText(at point: CGPoint) {
        Task { [weak self] in
            guard let self, let presentation = await self.viewModel.captureFromForceTouch(at: point) else { return }
            self.present(presentation, pointer: point)
        }
    }

    func hide() {
        guard panel.isVisible, !isDismissing else { return }
        isDismissing = true
        viewModel.stopTranslation()
        removeClickMonitor()
        let generation = presentationGeneration
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            finishHiding(generation: generation)
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Layout.fadeOutDuration
            self.panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                self?.finishHiding(generation: generation)
            }
        }
    }

    func stop() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        removeClickMonitor()
        presentationGeneration += 1
        // 标记为收起中：下屏触发的 resignKey 不再走淡出流程。
        isDismissing = true
        panel.orderOut(nil)
        isDismissing = false
        viewModel.reset()
    }

    // MARK: - Presentation

    /// `pointer` 为用力点按位置（全局显示坐标）；快捷键触发时为 nil，取当前鼠标位置。
    private func present(_ presentation: TranslatorPresentation, pointer: CGPoint?) {
        let screens = NSScreen.screens
        let primaryScreenHeight = screens.first?.frame.maxY ?? 0
        let pointerLocation = pointer.map {
            TranslatorPlacement.appKitPoint(fromGlobal: $0, primaryScreenHeight: primaryScreenHeight)
        } ?? NSEvent.mouseLocation
        // 部分应用报告的文字位置在屏幕之外（如已滚出可见区域），此时改为贴着指针弹出。
        let anchor = presentation.anchorRect
            .map { TranslatorPlacement.appKitRect(fromGlobal: $0, primaryScreenHeight: primaryScreenHeight) }
            .flatMap { rect in screens.contains { $0.frame.intersects(rect) } ? rect : nil }
        let focusPoint = anchor.map { NSPoint(x: $0.midX, y: $0.midY) } ?? pointerLocation
        guard let screen = screens.first(where: { $0.frame.contains(focusPoint) })
                ?? screens.first(where: { $0.frame.contains(pointerLocation) })
                ?? NSScreen.main else { return }

        placement = TranslatorPlacement(
            anchor: anchor ?? TranslatorPlacement.pointerAnchor(at: pointerLocation),
            pointer: pointerLocation,
            visibleFrame: screen.visibleFrame,
            width: TranslatorLayout.width,
            expectedHeight: TranslatorLayout.maximumHeight
        )
        presentationGeneration += 1
        isDismissing = false

        // 先让 SwiftUI 按新内容排版，尽量以正确高度弹出。
        panel.contentView?.layoutSubtreeIfNeeded()
        applyFrame()
        if !panel.isVisible {
            panel.alphaValue = 0
        }
        panel.orderFrontRegardless()
        panel.makeKey()
        panel.invalidateShadow()
        installClickMonitor()

        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            panel.alphaValue = 1
        } else {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Layout.fadeInDuration
                self.panel.animator().alphaValue = 1
            }
        }
    }

    private func finishHiding(generation: Int) {
        guard generation == presentationGeneration, isDismissing else { return }
        // 先下屏再复位：下屏触发的 resignKey 看到淡出仍在进行会直接跳过。
        panel.orderOut(nil)
        panel.alphaValue = 1
        isDismissing = false
        placement = nil
        viewModel.reset()
    }

    private func updateContentHeight(_ height: CGFloat) {
        guard height > 0, abs(height - contentHeight) >= 0.5 else { return }
        contentHeight = height
        // 高度在 SwiftUI 排版过程中上报，推迟到本轮排版结束后再改窗口尺寸。
        DispatchQueue.main.async { [weak self] in
            self?.applyFrame()
        }
    }

    private func applyFrame() {
        guard let placement else { return }
        let frame = placement.frame(height: contentHeight)
        guard frame != panel.frame else { return }
        panel.setFrame(frame, display: true)
        panel.invalidateShadow()
    }

    /// 全局监听只会收到发往其他应用的点击，即气泡之外的点击。
    private func installClickMonitor() {
        guard clickMonitor == nil else { return }
        clickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            self?.hide()
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
        guard event.window === panel, panel.isVisible, !isDismissing else { return event }
        // 输入法组字期间回车上屏、Esc 取消组字，都交给输入法。
        if (panel.firstResponder as? NSTextInputClient)?.hasMarkedText() == true {
            return event
        }

        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        switch Int(event.keyCode) {
        case kVK_Escape:
            hide()
            return nil
        case kVK_Return, kVK_ANSI_KeypadEnter:
            // 带修饰键的回车（如 ⌥↩ 换行）交给原文输入框。
            guard modifiers.isEmpty else { return event }
            performReturn()
            return nil
        default:
            guard modifiers == .command, let key = event.charactersIgnoringModifiers?.lowercased() else {
                return event
            }
            return handleCommandKey(key, event: event)
        }
    }

    private func performReturn() {
        guard let session = viewModel.session else {
            // 只有提示时回车即关闭。
            hide()
            return
        }
        switch session.returnAction {
        case .translate, .retry:
            viewModel.translateCurrentSource()
        case .copyAndClose:
            if let translation = viewModel.translationToCopy {
                writeToPasteboard(translation)
                hide()
            }
        case .none:
            break
        }
    }

    /// OI 没有可见的主菜单、气泡出现时也不激活 OI，编辑快捷键在这里直接分派给第一响应者。
    private func handleCommandKey(_ key: String, event: NSEvent) -> NSEvent? {
        switch key {
        case "c":
            // 选中了部分原文或译文时复制选中的部分；都没有选中时复制整段译文并保留气泡。
            if let editor = panel.firstResponder as? NSTextView, editor.isFieldEditor {
                if editor.selectedRange().length > 0 {
                    editor.copy(nil)
                    return nil
                }
            } else if copySelectionFromFirstResponder() {
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
    private func copySelectionFromFirstResponder() -> Bool {
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
