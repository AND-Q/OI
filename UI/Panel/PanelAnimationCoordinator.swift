import AppKit
import QuartzCore

/// Single driver for every window-geometry animation of the launcher panel,
/// mirroring the native Spotlight `WindowAnimationCoordinator`: a vsync-locked
/// clock steps the window frame every display refresh and the SwiftUI content
/// follows the published geometry, so the panel and its content can never
/// drift apart.
@MainActor
final class PanelAnimationCoordinator: ObservableObject {
    private enum Layout {
        /// Gap between the menu bar and the panel's top edge, matching Spotlight.
        static let topGap: CGFloat = 94
        /// Critically damped spring response; smaller reads snappier.
        static let resizeResponse: TimeInterval = 0.22
        static let fadeInDuration: TimeInterval = 0.18
        static let fadeOutDuration: TimeInterval = 0.15
        /// Snap and finish once the remaining distance is imperceptible.
        static let settleDistance: CGFloat = 0.5
    }

    /// Geometry the SwiftUI content renders with; republished every frame.
    @Published private(set) var currentHeight: CGFloat
    @Published private(set) var cornerRadius: CGFloat

    /// Display the panel lives on; set by the owner whenever the panel is shown
    /// or its screen is re-resolved, so resizes never jump across displays.
    var screen: NSScreen?

    private let panel: NSPanel
    private var clock: DisplayStepClock?
    private var resizeState: (
        start: CGFloat, target: CGFloat, startRadius: CGFloat, targetRadius: CGFloat, startTime: CFTimeInterval
    )?
    private var alphaState: (
        from: CGFloat, to: CGFloat, startTime: CFTimeInterval, duration: TimeInterval, completion: (() -> Void)?
    )?
    private var isDismissing = false

    /// Breaks the clock ⇄ CADisplayLink target retain cycle if the owner is
    /// released while an animation is still running.
    deinit {
        clock?.stop()
    }

    init(panel: NSPanel, initialHeight: CGFloat) {
        self.panel = panel
        self.currentHeight = initialHeight
        let radius = Self.cornerRadius(forHeight: initialHeight)
        self.cornerRadius = radius
        updateLayerCornerRadius(radius)
    }

    var isDismissalInProgress: Bool { isDismissing }

    /// Capsule radius while collapsed, expanding radius otherwise.
    static func cornerRadius(forHeight height: CGFloat) -> CGFloat {
        height <= LauncherLayout.searchHeight + 0.5
            ? LauncherLayout.compactCornerRadius
            : LauncherLayout.expandedCornerRadius
    }

    /// The panel keeps a fixed top edge and horizontal center; its height grows
    /// downward, exactly like the native Spotlight panel.
    static func frame(for screen: NSScreen?, height: CGFloat) -> NSRect {
        let visibleFrame = screen?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let x = visibleFrame.midX - LauncherLayout.width / 2
        let y = visibleFrame.maxY - Layout.topGap - height
        let clampedY = max(visibleFrame.minY, min(y, visibleFrame.maxY - height))
        return NSRect(
            x: x.rounded(),
            y: clampedY.rounded(),
            width: LauncherLayout.width,
            height: height.rounded()
        )
    }

    /// Drops any in-flight transition and adopts `height` immediately.
    func prepareForPresentation(height: CGFloat) {
        stopAnimations()
        currentHeight = height
        let radius = Self.cornerRadius(forHeight: height)
        cornerRadius = radius
        updateLayerCornerRadius(radius)
    }

    /// Grows/shrinks the window to `height`, retargeting from the current
    /// interpolated position when a resize is already in flight.
    func resize(toHeight height: CGFloat) {
        guard height != currentHeight else { return }

        resizeState = (
            start: currentHeight,
            target: height,
            startRadius: cornerRadius,
            targetRadius: Self.cornerRadius(forHeight: height),
            startTime: CACurrentMediaTime()
        )
        ensureClock()
    }

    /// Fades the panel in after it has been ordered front.
    func fadeIn() {
        panel.alphaValue = 0
        alphaState = (from: 0, to: 1, startTime: CACurrentMediaTime(), duration: Layout.fadeInDuration, completion: nil)
        ensureClock()
    }

    /// Fades the panel out and orders it out once fully transparent.
    func fadeOutAndOrderOut() {
        isDismissing = true
        alphaState = (
            from: panel.alphaValue,
            to: 0,
            startTime: CACurrentMediaTime(),
            duration: Layout.fadeOutDuration,
            completion: { [weak self] in
                guard let self else { return }
                self.panel.orderOut(nil)
                self.panel.alphaValue = 1
                self.isDismissing = false
            }
        )
        ensureClock()
    }

    /// Reverses an in-flight dismissal, fading back in from the current alpha
    /// instead of restarting from transparent.
    func cancelDismissal() {
        guard isDismissing else { return }
        stopAnimations()
        alphaState = (
            from: panel.alphaValue,
            to: 1,
            startTime: CACurrentMediaTime(),
            duration: Layout.fadeInDuration,
            completion: nil
        )
        ensureClock()
    }

    /// Cancels every running animation without side effects.
    func stopAnimations() {
        clock?.stop()
        clock = nil
        resizeState = nil
        alphaState = nil
        isDismissing = false
    }

    private func ensureClock() {
        guard clock == nil else { return }
        let clock = DisplayStepClock(window: panel) { [weak self] in self?.step() }
        self.clock = clock
        clock.start()
    }

    private func step() {
        let now = CACurrentMediaTime()
        var isBusy = false

        if var resize = resizeState {
            let settled = Self.springSettled(
                elapsed: now - resize.startTime,
                response: Layout.resizeResponse
            )
            let height = resize.start + (resize.target - resize.start) * settled
            if height != currentHeight { currentHeight = height }
            let radius = resize.startRadius + (resize.targetRadius - resize.startRadius) * settled
            cornerRadius = radius
            // `display: false` pipelines the commit instead of blocking per frame.
            panel.setFrame(Self.frame(for: screen, height: height), display: false)
            setLayerCornerRadius(radius)

            if abs(resize.target - height) < Layout.settleDistance
                || now - resize.startTime > Layout.resizeResponse * 3 {
                currentHeight = resize.target
                cornerRadius = resize.targetRadius
                panel.setFrame(Self.frame(for: screen, height: resize.target), display: false)
                updateLayerCornerRadius(resize.targetRadius)
                resizeState = nil
            } else {
                isBusy = true
            }
        }

        if let alpha = alphaState {
            let fraction = min((now - alpha.startTime) / alpha.duration, 1)
            panel.alphaValue = alpha.from + (alpha.to - alpha.from) * CGFloat(fraction)
            if fraction >= 1 {
                alphaState = nil
                updateLayerCornerRadius(cornerRadius)
                alpha.completion?()
            } else {
                isBusy = true
            }
        }

        if !isBusy {
            clock?.stop()
            clock = nil
        }
    }

    /// Per-frame corner radius update only. Shadow recompute is deliberately
    /// kept off the animation loop: `invalidateShadow` makes WindowServer
    /// rebuild the shadow from the window's alpha, too costly at display rate.
    private func setLayerCornerRadius(_ radius: CGFloat) {
        for view in [panel.contentView?.superview, panel.contentView].compactMap({ $0 }) {
            if view.layer?.cornerRadius != radius {
                view.layer?.cornerRadius = radius
            }
        }
    }

    /// Updates the AppKit host layers' corner radii and masks so macOS WindowServer
    /// derives the window shadow from the exact capsule/rounded shape rather than
    /// falling back to a rectangular bounds shadow. Runs on init and whenever a
    /// geometry transition settles — never per animation frame.
    private func updateLayerCornerRadius(_ radius: CGFloat) {
        for view in [panel.contentView?.superview, panel.contentView].compactMap({ $0 }) {
            view.wantsLayer = true
            if view.layer?.cornerRadius != radius {
                view.layer?.cornerRadius = radius
            }
            if view.layer?.cornerCurve != .continuous {
                view.layer?.cornerCurve = .continuous
            }
            if view.layer?.masksToBounds != true {
                view.layer?.masksToBounds = true
            }
        }
        panel.invalidateShadow()
    }

    /// Critically damped spring: s(t) = 1 - (1 + ω·t)·e^(-ω·t), ω = 6/response.
    private static func springSettled(elapsed: TimeInterval, response: TimeInterval) -> CGFloat {
        let x = elapsed * 6.0 / response
        return CGFloat(1 - (1 + x) * exp(-x))
    }
}

/// Vsync-locked step clock: one `onTick` per display refresh. On macOS 14+ the
/// link synchronizes with the panel window's own screen and delivers on the
/// main thread — correct on ProMotion and mixed-refresh multi-display setups.
/// macOS 13 falls back to CVDisplayLink with a main-queue hop.
private final class DisplayStepClock {
    private let onTick: () -> Void
    private weak var window: NSWindow?
    /// `CADisplayLink` on macOS 14+, typed as `AnyObject` because the type is
    /// unavailable on the macOS 13 deployment target.
    private var cadence: AnyObject?
    private var cvDisplayLink: CVDisplayLink?

    init(window: NSWindow, onTick: @escaping () -> Void) {
        self.window = window
        self.onTick = onTick
    }

    deinit {
        stop()
    }

    func start() {
        guard cadence == nil, cvDisplayLink == nil else { return }
        if #available(macOS 14.0, *), let window, window.isVisible {
            let link = window.displayLink(target: self, selector: #selector(stepLink(_:)))
            link.add(to: .main, forMode: .common)
            cadence = link
            return
        }
        var link: CVDisplayLink?
        guard CVDisplayLinkCreateWithActiveCGDisplays(&link) == kCVReturnSuccess, let link else { return }
        let context = Unmanaged.passUnretained(self).toOpaque()
        CVDisplayLinkSetOutputCallback(link, { _, _, _, _, _, userData in
            guard let userData else { return kCVReturnSuccess }
            Unmanaged<DisplayStepClock>.fromOpaque(userData).takeUnretainedValue().fire()
            return kCVReturnSuccess
        }, context)
        cvDisplayLink = link
        CVDisplayLinkStart(link)
    }

    func stop() {
        if #available(macOS 14.0, *), let link = cadence as? CADisplayLink {
            link.remove(from: .main, forMode: .common)
            link.invalidate()
        }
        cadence = nil
        if let cvDisplayLink {
            CVDisplayLinkStop(cvDisplayLink)
        }
        cvDisplayLink = nil
    }

    /// CADisplayLink callback: invoked in-sync with the panel's display.
    @objc private func stepLink(_ sender: Any) {
        if Thread.isMainThread {
            onTick()
        } else {
            DispatchQueue.main.async { [weak self] in self?.onTick() }
        }
    }

    /// Runs on the display link's background thread; hop to main.
    private func fire() {
        DispatchQueue.main.async { [weak self] in self?.onTick() }
    }
}
