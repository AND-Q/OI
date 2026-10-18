import AppKit
import SwiftUI

/// 一个翻译气泡：不激活 OI 的浮动面板，弹在原文旁边，持有自己的翻译状态（`TranslatorViewModel`）。
/// 面板成为 key 窗口以接收 Esc / 回车与原文编辑，但 OI 不切到前台，原应用保持激活。
/// 用力点按取到单词时，另用一个不接收鼠标的窗口在原文单词上叠加黄色高亮，随气泡出现与收起。
/// 按住顶部一行或底部提示栏可拖动（见 `TranslatorView`），拖动只改位置；何时收起由 `TranslatorPanelController` 决定。
@MainActor
final class TranslatorBubble {
    private enum Layout {
        static let fadeInDuration: TimeInterval = 0.12
        static let fadeOutDuration: TimeInterval = 0.15
        /// 首次排版完成前的估计高度。
        static let initialHeight: CGFloat = 120
        /// 高亮比单词区域向外扩展的距离。
        static let highlightPadding: CGFloat = 2
        /// 等待鼠标按键松开时的检查间隔。
        static let mouseReleasePollInterval: Duration = .milliseconds(10)
        /// 松开后等原应用处理完这次点击，再让气泡接管键盘。
        static let keyFocusDelayAfterRelease: Duration = .milliseconds(100)
    }

    let viewModel: TranslatorViewModel
    let panel: TranslatorPanel
    private let highlight: NSPanel

    /// 点按左上角的关闭按钮。
    var onClose: (() -> Void)?
    /// 点按右上角的图钉。
    var onPin: (() -> Void)?
    /// 面板失去 key（点到其他应用或其他窗口）。
    var onResignKey: (() -> Void)?
    /// 淡出完成、已从屏幕移除。
    var onHidden: (() -> Void)?

    private var scrollMonitor: Any?
    /// 鼠标按键松开后让气泡接管键盘的等待任务。
    private var keyFocusTask: Task<Void, Never>?
    private var placement: TranslatorPlacement?
    private var contentHeight = Layout.initialHeight
    /// 每次弹出递增：淡出完成时据此判断期间是否又弹出了新的内容。
    private var presentationGeneration = 0
    private(set) var isDismissing = false
    /// 正在按内容调整气泡位置与尺寸：期间的移动通知来自 OI 自己，不是用户拖动。
    private var isApplyingFrame = false
    /// 用户拖动过：不再贴着原文摆放，左上角留在放下的位置。弹出新的内容时复位。
    private var isMoved = false
    private var moveObservers: [any NSObjectProtocol] = []

    init(viewModel: TranslatorViewModel) {
        self.viewModel = viewModel
        panel = TranslatorPanel(
            contentRect: NSRect(x: 0, y: 0, width: TranslatorLayout.width, height: Layout.initialHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        highlight = NSPanel(
            contentRect: .zero,
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
        // 只能按住气泡顶部或底部拖动（见 TranslatorView），不随背景拖动，以免与选中译文冲突。
        panel.isMovable = true
        panel.isMovableByWindowBackground = false
        panel.animationBehavior = .none
        panel.isReleasedWhenClosed = false

        let hostingView = NSHostingView(
            rootView: TranslatorView(
                viewModel: viewModel,
                closeButton: TranslatorWindowCloseButton { [weak self] in self?.onClose?() },
                onPin: { [weak self] in self?.onPin?() }
            ) { [weak self] height in
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

        highlight.isOpaque = false
        highlight.backgroundColor = .clear
        highlight.hasShadow = false
        // 点击穿透到下面的应用，不影响原应用的操作。
        highlight.ignoresMouseEvents = true
        highlight.level = .floating
        highlight.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        highlight.hidesOnDeactivate = false
        highlight.animationBehavior = .none
        highlight.isReleasedWhenClosed = false
        let highlightView = TranslatorHighlightView()
        highlightView.wantsLayer = true
        highlight.contentView = highlightView

        panel.onResignKey = { [weak self] in self?.onResignKey?() }
        moveObservers = [NSWindow.willMoveNotification, NSWindow.didMoveNotification].map { name in
            NotificationCenter.default.addObserver(forName: name, object: panel, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.panelDidMove()
                }
            }
        }
    }

    isolated deinit {
        for observer in moveObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        if let scrollMonitor {
            NSEvent.removeMonitor(scrollMonitor)
        }
        keyFocusTask?.cancel()
    }

    var isVisible: Bool { panel.isVisible && !isDismissing }

    // MARK: - Presentation

    /// `pointer` 为用力点按位置（全局显示坐标）；快捷键触发时为 nil，取当前鼠标位置。
    func present(_ presentation: TranslatorPresentation, pointer: CGPoint?, level: NSWindow.Level) {
        let screens = NSScreen.screens
        let primaryScreenHeight = screens.first?.frame.maxY ?? 0
        let pointerLocation = pointer.map {
            TranslatorPlacement.appKitPoint(fromGlobal: $0, primaryScreenHeight: primaryScreenHeight)
        } ?? NSEvent.mouseLocation
        // 部分应用报告的文字位置在屏幕之外（如已滚出可见区域），此时改为贴着指针弹出。
        let anchor = presentation.anchorRect
            .map { TranslatorPlacement.appKitRect(fromGlobal: $0, primaryScreenHeight: primaryScreenHeight) }
            .flatMap { rect in screens.contains { $0.frame.intersects(rect) } ? rect : nil }
        // 只给用力点按取到的单词加高亮：选区由原应用显示选中状态，剪贴板没有位置。
        let highlightFrame = viewModel.session?.source == .word
            ? anchor?.insetBy(dx: -Layout.highlightPadding, dy: -Layout.highlightPadding)
            : nil
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
        // 新的内容贴着原文弹出，此前拖动过的位置不再沿用。
        isMoved = false
        setLevel(level)

        // 先让 SwiftUI 按新内容排版，尽量以正确高度弹出。
        panel.contentView?.layoutSubtreeIfNeeded()
        applyFrame()
        if !panel.isVisible {
            panel.alphaValue = 0
        }
        // 高亮先上屏，气泡随后排在它之上。
        if let highlightFrame {
            highlight.setFrame(highlightFrame, display: true)
            if !highlight.isVisible {
                highlight.alphaValue = 0
            }
            highlight.orderFrontRegardless()
            installScrollMonitor()
        } else {
            removeHighlight()
        }
        panel.orderFrontRegardless()
        makeKeyAfterMouseRelease()
        panel.invalidateShadow()

        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            panel.alphaValue = 1
            highlight.alphaValue = 1
        } else {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Layout.fadeInDuration
                self.panel.animator().alphaValue = 1
                self.highlight.animator().alphaValue = 1
            }
        }
    }

    /// 中断翻译并淡出，完成后清空翻译状态并通知 `onHidden`。
    func hide() {
        guard panel.isVisible, !isDismissing else { return }
        isDismissing = true
        viewModel.stopTranslation()
        cancelKeyFocusTask()
        removeScrollMonitor()
        let generation = presentationGeneration
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            finishHiding(generation: generation)
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Layout.fadeOutDuration
            self.panel.animator().alphaValue = 0
            self.highlight.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                self?.finishHiding(generation: generation)
            }
        }
    }

    /// 立即移除，不经淡出（退出 OI 时）。
    func stop() {
        removeHighlight()
        cancelKeyFocusTask()
        presentationGeneration += 1
        // 标记为收起中：下屏触发的 resignKey 不再走淡出流程。
        isDismissing = true
        panel.orderOut(nil)
        isDismissing = false
        viewModel.reset()
    }

    func setLevel(_ level: NSWindow.Level) {
        panel.level = level
        highlight.level = level
    }

    func removeHighlight() {
        removeScrollMonitor()
        highlight.orderOut(nil)
    }

    /// 用力点按时气泡在手指仍按着时弹出，原应用可能在按住期间（把轻微位移当作开始拖动选中的文字）
    /// 或松开时（处理点在选区上的点击）拿回键盘焦点；气泡此时若已接管键盘，会因失去 key 而收起。
    /// 因此按键按着时只显示气泡，松开后稍等原应用处理完这次点击再接管键盘。
    private func makeKeyAfterMouseRelease() {
        cancelKeyFocusTask()
        guard NSEvent.pressedMouseButtons & 1 != 0 else {
            panel.makeKey()
            return
        }
        let generation = presentationGeneration
        keyFocusTask = Task { [weak self] in
            while NSEvent.pressedMouseButtons & 1 != 0 {
                try? await Task.sleep(for: Layout.mouseReleasePollInterval)
                guard !Task.isCancelled else { return }
            }
            try? await Task.sleep(for: Layout.keyFocusDelayAfterRelease)
            guard let self, !Task.isCancelled, generation == self.presentationGeneration,
                  self.panel.isVisible, !self.isDismissing else { return }
            self.panel.makeKey()
        }
    }

    private func cancelKeyFocusTask() {
        keyFocusTask?.cancel()
        keyFocusTask = nil
    }

    private func finishHiding(generation: Int) {
        guard generation == presentationGeneration, isDismissing else { return }
        // 先下屏再复位：下屏触发的 resignKey 看到淡出仍在进行会直接跳过。
        highlight.orderOut(nil)
        panel.orderOut(nil)
        panel.alphaValue = 1
        isDismissing = false
        placement = nil
        isMoved = false
        viewModel.reset()
        onHidden?()
    }

    // MARK: - Frame

    private func updateContentHeight(_ height: CGFloat) {
        guard height > 0, abs(height - contentHeight) >= 0.5 else { return }
        contentHeight = height
        // 高度在 SwiftUI 排版过程中上报，推迟到本轮排版结束后再改窗口尺寸。
        DispatchQueue.main.async { [weak self] in
            self?.applyFrame()
        }
    }

    private func applyFrame() {
        guard var placement else { return }
        if isMoved {
            // 拖动过的气泡：左上角留在放下的位置（按当前位置计算，拖动途中调整高度也不会跳回），内容增长时向下伸长。
            placement = TranslatorPlacement(
                keepingTopLeftOf: panel.frame,
                visibleFrame: panel.screen?.visibleFrame ?? placement.visibleFrame
            )
        }
        let frame = placement.frame(height: contentHeight)
        guard frame != panel.frame else { return }
        isApplyingFrame = true
        panel.setFrame(frame, display: true)
        isApplyingFrame = false
        panel.invalidateShadow()
    }

    /// 移动通知不是来自按内容调整尺寸时，即用户拖动了气泡。
    private func panelDidMove() {
        guard !isApplyingFrame, panel.isVisible, !isDismissing else { return }
        isMoved = true
    }

    // MARK: - Highlight

    /// 原文随滚动移动后高亮会错位：滚动其他应用时先收起高亮，气泡保留。
    /// 全局监听只会收到发往其他应用的滚动，在气泡内滚动译文不受影响。
    private func installScrollMonitor() {
        guard scrollMonitor == nil else { return }
        scrollMonitor = NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel) { [weak self] _ in
            self?.removeHighlight()
        }
    }

    private func removeScrollMonitor() {
        if let scrollMonitor {
            NSEvent.removeMonitor(scrollMonitor)
        }
        scrollMonitor = nil
    }
}

/// 气泡左上角的关闭按钮，外观照 macOS 窗口的关闭按钮：平时是与背景接近的浅灰圆点，不抢眼；
/// 指针移上去时变为系统的红色并显示 ×。系统自带的按钮只在标题栏里才有悬停变色，放进气泡后需借助未公开的接口，
/// 因此自行绘制。
struct TranslatorWindowCloseButton: NSViewRepresentable {
    let action: () -> Void

    func makeNSView(context: Context) -> TranslatorCloseButtonView {
        let view = TranslatorCloseButtonView()
        view.onClick = action
        return view
    }

    func updateNSView(_ view: TranslatorCloseButtonView, context: Context) {
        view.onClick = action
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: TranslatorCloseButtonView, context: Context) -> CGSize? {
        TranslatorCloseButtonView.size
    }
}

final class TranslatorCloseButtonView: NSView {
    static let size = NSSize(width: 14, height: 14)
    /// 与系统窗口按钮相同的圆点直径。
    private static let diameter: CGFloat = 12
    /// 系统关闭按钮的红色、描边与 × 的颜色。
    private static let fillColor = NSColor(srgbRed: 1, green: 0.373, blue: 0.341, alpha: 1)
    private static let pressedFillColor = NSColor(srgbRed: 0.75, green: 0.286, blue: 0.259, alpha: 1)
    private static let borderColor = NSColor(srgbRed: 0.878, green: 0.267, blue: 0.243, alpha: 1)
    private static let glyphColor = NSColor(srgbRed: 0.302, green: 0, blue: 0, alpha: 0.7)

    var onClick: (() -> Void)?
    private var isPressed = false {
        didSet { needsDisplay = true }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        toolTip = "关闭"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize { Self.size }

    /// 气泡不是 key 窗口时（如固定后点过别处）点一次即关闭。
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas {
            removeTrackingArea(area)
        }
        // OI 不在前台，只有 activeAlways 的跟踪区域才会收到指针进出。
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))
    }

    override func mouseEntered(with event: NSEvent) {
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        isPressed = true
    }

    override func mouseDragged(with event: NSEvent) {
        isPressed = contains(event)
    }

    override func mouseUp(with event: NSEvent) {
        isPressed = false
        if contains(event) {
            onClick?()
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = NSRect(
            x: (bounds.width - Self.diameter) / 2,
            y: (bounds.height - Self.diameter) / 2,
            width: Self.diameter,
            height: Self.diameter
        )
        let circle = NSBezierPath(ovalIn: rect.insetBy(dx: 0.25, dy: 0.25))
        circle.lineWidth = 0.5
        guard isPressed || isPointerInside else {
            // 平时：随浅色与深色外观变化的浅灰，与毛玻璃背景接近。
            NSColor.labelColor.withAlphaComponent(0.16).setFill()
            circle.fill()
            NSColor.labelColor.withAlphaComponent(0.08).setStroke()
            circle.stroke()
            return
        }
        (isPressed ? Self.pressedFillColor : Self.fillColor).setFill()
        circle.fill()
        Self.borderColor.setStroke()
        circle.stroke()

        let inset = Self.diameter * 0.32
        let glyphRect = rect.insetBy(dx: inset, dy: inset)
        let glyph = NSBezierPath()
        glyph.move(to: NSPoint(x: glyphRect.minX, y: glyphRect.minY))
        glyph.line(to: NSPoint(x: glyphRect.maxX, y: glyphRect.maxY))
        glyph.move(to: NSPoint(x: glyphRect.minX, y: glyphRect.maxY))
        glyph.line(to: NSPoint(x: glyphRect.maxX, y: glyphRect.minY))
        glyph.lineWidth = 1.1
        glyph.lineCapStyle = .round
        Self.glyphColor.setStroke()
        glyph.stroke()
    }

    /// 按指针的实际位置判断是否悬停：气泡收起时收不到指针离开，再次弹出时也不会停留在悬停状态。
    private var isPointerInside: Bool {
        guard let window else { return false }
        return bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil))
    }

    private func contains(_ event: NSEvent) -> Bool {
        bounds.contains(convert(event.locationInWindow, from: nil))
    }

    // MARK: - Accessibility

    override func isAccessibilityElement() -> Bool { true }

    override func accessibilityRole() -> NSAccessibility.Role? { .button }

    override func accessibilityLabel() -> String? { "关闭" }

    override func accessibilityPerformPress() -> Bool {
        onClick?()
        return true
    }
}
