import AppKit

/// 截图翻译的框选界面：每块屏幕铺上进入框选时定格的画面，盖一层半透明遮罩，按住拖动框选区域，
/// 选区内保持原样、选区外变暗。框选与识别都基于定格的这一帧，期间视频播放、页面滚动都不影响选区。
/// 遮罩不激活 OI，原应用保持在前台；遮罩可成为 key 窗口，按键由翻译面板的按键监听统一处理。
@MainActor
final class ScreenSelectionOverlay {
    /// 遮罩的窗口层级：盖住菜单栏、程序坞与全屏应用。翻译气泡在框选期间放在更高一层。
    static let level = NSWindow.Level.screenSaver
    /// 选区的最小边长（点）：拖动距离更小时视为单击，不改变选区。
    static let minimumSelectionSize: CGFloat = 4

    /// 开始拖出新的选区。
    var onSelectionStart: (() -> Void)?
    /// 选区确定，参数为选区的全局显示坐标（原点在主屏左上角、y 轴向下）与定格的画面。
    var onSelection: ((CGRect, ScreenSnapshot) -> Void)?
    /// 右键或有其他应用切到前台：退出框选。
    var onCancel: (() -> Void)?

    private var surfaces: [(panel: ScreenSelectionPanel, view: ScreenSelectionView)] = []
    private var snapshot: ScreenSnapshot?
    private var activationObserver: (any NSObjectProtocol)?

    var isActive: Bool { !surfaces.isEmpty }

    func begin(showing snapshot: ScreenSnapshot) {
        guard !isActive else { return }
        self.snapshot = snapshot
        for screen in NSScreen.screens {
            let panel = ScreenSelectionPanel(
                contentRect: screen.frame,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.level = Self.level
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
            panel.hidesOnDeactivate = false
            panel.becomesKeyOnlyIfNeeded = false
            panel.isMovable = false
            panel.animationBehavior = .none
            panel.isReleasedWhenClosed = false

            let bounds = NSRect(origin: .zero, size: screen.frame.size)
            let view = ScreenSelectionView(frame: bounds)
            view.onDragBegan = { [weak self, weak view] in
                guard let self, let view else { return }
                self.clearSelections(except: view)
                self.onSelectionStart?()
            }
            view.onDragEnded = { [weak self, weak panel, weak view] rect in
                guard let self, let panel, let view, let snapshot = self.snapshot else { return }
                self.onSelection?(ScreenSelectionOverlay.globalRect(of: rect, in: view, of: panel), snapshot)
            }
            view.onRightClick = { [weak self] in
                self?.onCancel?()
            }
            // 定格的画面铺在遮罩下面；这块屏幕在截屏之后才接入、没有画面时遮罩下仍是实时的屏幕。
            if let image = Self.image(for: screen, in: snapshot) {
                let backdrop = ScreenSnapshotView(frame: bounds, image: image)
                view.autoresizingMask = [.width, .height]
                backdrop.addSubview(view)
                panel.contentView = backdrop
            } else {
                panel.contentView = view
            }
            panel.setFrame(screen.frame, display: false)
            _ = panel.makeFirstResponder(view)
            panel.orderFrontRegardless()
            surfaces.append((panel: panel, view: view))
        }
        makeKey()
        NSCursor.crosshair.set()
        // 遮罩不激活 OI，期间有应用切到前台（如 ⌘Tab）说明用户已离开，退出框选，以免遮罩一直挡住屏幕。
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.onCancel?()
            }
        }
    }

    func end() {
        guard isActive else { return }
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
            self.activationObserver = nil
        }
        for surface in surfaces {
            surface.panel.orderOut(nil)
        }
        surfaces.removeAll()
        snapshot = nil
    }

    func contains(_ window: NSWindow?) -> Bool {
        guard let window else { return false }
        return surfaces.contains { $0.panel === window }
    }

    /// 由拖动起点与当前位置得到的选区，限制在视图范围内（选区不跨越屏幕）。
    nonisolated static func selectionRect(from origin: NSPoint, to point: NSPoint, within bounds: NSRect) -> NSRect {
        let x = min(max(point.x, bounds.minX), bounds.maxX)
        let y = min(max(point.y, bounds.minY), bounds.maxY)
        return NSRect(
            x: min(origin.x, x),
            y: min(origin.y, y),
            width: abs(x - origin.x),
            height: abs(y - origin.y)
        )
    }

    /// 让指针所在屏幕的遮罩接收按键。
    private func makeKey() {
        let location = NSEvent.mouseLocation
        let surface = surfaces.first { $0.panel.frame.contains(location) } ?? surfaces.first
        surface?.panel.makeKey()
    }

    private static func image(for screen: NSScreen, in snapshot: ScreenSnapshot) -> CGImage? {
        let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        return snapshot.displays.first { $0.displayID == displayID }?.image
    }

    /// 新的选区只有一个：在一块屏幕上开始拖动时清除其他屏幕上的旧选区。
    private func clearSelections(except view: ScreenSelectionView) {
        for surface in surfaces where surface.view !== view {
            surface.view.selection = nil
        }
    }

    private static func globalRect(of rect: NSRect, in view: NSView, of panel: NSWindow) -> CGRect {
        let screenRect = panel.convertToScreen(view.convert(rect, to: nil))
        let primaryScreenHeight = NSScreen.screens.first?.frame.maxY ?? 0
        return TranslatorPlacement.globalRect(fromAppKit: screenRect, primaryScreenHeight: primaryScreenHeight)
    }
}

/// 一块屏幕上的框选遮罩窗口：不激活 OI，但可以成为 key 窗口以接收 Esc 等按键。
final class ScreenSelectionPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// 框选遮罩下定格的屏幕画面：作为图层内容由系统合成，拖动选框重绘遮罩时不必重绘整幅画面。
final class ScreenSnapshotView: NSView {
    private let image: CGImage

    init(frame: NSRect, image: CGImage) {
        self.image = image
        super.init(frame: frame)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.contents = image
    }
}

/// 框选遮罩的内容：选区外变暗、选区描边，处理拖动框选与右键。
final class ScreenSelectionView: NSView {
    private static let dimmingOpacity: CGFloat = 0.3
    private static let borderWidth: CGFloat = 1.5

    /// 视图坐标中的选区；尚未框选时为 nil。
    var selection: NSRect? {
        didSet { needsDisplay = true }
    }
    var onDragBegan: (() -> Void)?
    var onDragEnded: ((NSRect) -> Void)?
    var onRightClick: (() -> Void)?

    private var dragOrigin: NSPoint?
    private var isDragging = false

    override var acceptsFirstResponder: Bool { true }

    /// 遮罩不是 key 窗口时（如刚点过翻译气泡）第一次点按也直接开始框选。
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas {
            removeTrackingArea(area)
        }
        // OI 不在前台，只有 activeAlways 的跟踪区域才会收到 cursorUpdate，从而显示十字指针。
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.cursorUpdate, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))
    }

    override func cursorUpdate(with event: NSEvent) {
        NSCursor.crosshair.set()
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.clear.setFill()
        dirtyRect.fill(using: .copy)

        let dimmed = NSBezierPath(rect: bounds)
        if let selection {
            dimmed.append(NSBezierPath(rect: selection))
            dimmed.windingRule = .evenOdd
        }
        NSColor.black.withAlphaComponent(Self.dimmingOpacity).setFill()
        dimmed.fill()

        guard let selection else { return }
        let inset = -Self.borderWidth / 2
        let border = NSBezierPath(rect: selection.insetBy(dx: inset, dy: inset))
        border.lineWidth = Self.borderWidth
        NSColor.controlAccentColor.setStroke()
        border.stroke()
    }

    override func mouseDown(with event: NSEvent) {
        dragOrigin = convert(event.locationInWindow, from: nil)
        isDragging = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragOrigin else { return }
        let rect = ScreenSelectionOverlay.selectionRect(
            from: dragOrigin,
            to: convert(event.locationInWindow, from: nil),
            within: bounds
        )
        if !isDragging {
            // 拖动距离过小视为单击，保留原有选区与译文。
            guard max(rect.width, rect.height) >= ScreenSelectionOverlay.minimumSelectionSize else { return }
            isDragging = true
            onDragBegan?()
        }
        selection = rect
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            dragOrigin = nil
            isDragging = false
        }
        guard isDragging, let rect = selection else { return }
        // 拖成一条线时不作为选区。
        guard min(rect.width, rect.height) >= ScreenSelectionOverlay.minimumSelectionSize else {
            selection = nil
            return
        }
        onDragEnded?(rect)
    }

    override func rightMouseDown(with event: NSEvent) {
        onRightClick?()
    }

    /// 按键由翻译面板的按键监听处理，其余按键在此吞掉，避免系统提示音。
    override func keyDown(with event: NSEvent) {}
}
