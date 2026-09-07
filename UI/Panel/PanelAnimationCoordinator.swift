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

    init(panel: NSPanel, initialHeight: CGFloat) {
        self.panel = panel
        self.currentHeight = initialHeight
        self.cornerRadius = Self.cornerRadius(forHeight: initialHeight)
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
        return NSRect(
            x: visibleFrame.midX - LauncherLayout.width / 2,
            y: visibleFrame.maxY - Layout.topGap - height,
            width: LauncherLayout.width,
            height: height
        )
    }

    /// Drops any in-flight transition and adopts `height` immediately.
    func prepareForPresentation(height: CGFloat) {
        stopAnimations()
        currentHeight = height
        cornerRadius = Self.cornerRadius(forHeight: height)
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
        let clock = DisplayStepClock { [weak self] in self?.step() }
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
            cornerRadius = resize.startRadius + (resize.targetRadius - resize.startRadius) * settled
            // `display: false` pipelines the commit instead of blocking per frame.
            panel.setFrame(Self.frame(for: screen, height: height), display: false)

            if abs(resize.target - height) < Layout.settleDistance
                || now - resize.startTime > Layout.resizeResponse * 3 {
                currentHeight = resize.target
                cornerRadius = resize.targetRadius
                panel.setFrame(Self.frame(for: screen, height: resize.target), display: false)
                resizeState = nil
            } else {
                isBusy = true
            }
            // The glass surface doesn't participate in the system's automatic
            // window-shadow derivation, so re-derive it after every geometry
            // change — otherwise the shadow keeps a stale (rectangular) shape
            // and its corners peek out around the capsule.
            panel.invalidateShadow()
        }

        if let alpha = alphaState {
            let fraction = min((now - alpha.startTime) / alpha.duration, 1)
            panel.alphaValue = alpha.from + (alpha.to - alpha.from) * CGFloat(fraction)
            if fraction >= 1 {
                alphaState = nil
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

    /// Critically damped spring: s(t) = 1 - (1 + ω·t)·e^(-ω·t), ω = 6/response.
    private static func springSettled(elapsed: TimeInterval, response: TimeInterval) -> CGFloat {
        let x = elapsed * 6.0 / response
        return CGFloat(1 - (1 + x) * exp(-x))
    }
}

/// Vsync-locked step clock: one `onTick` per display refresh, hopped onto the
/// main thread. CVDisplayLink is the only display-linked clock available across
/// the deployment target range (macOS 13+).
private final class DisplayStepClock {
    private var displayLink: CVDisplayLink?
    private let onTick: () -> Void

    init(onTick: @escaping () -> Void) {
        self.onTick = onTick
    }

    deinit {
        stop()
    }

    func start() {
        guard displayLink == nil else { return }
        var link: CVDisplayLink?
        guard CVDisplayLinkCreateWithActiveCGDisplays(&link) == kCVReturnSuccess, let link else { return }
        let context = Unmanaged.passUnretained(self).toOpaque()
        CVDisplayLinkSetOutputCallback(link, { _, _, _, _, _, userData in
            guard let userData else { return kCVReturnSuccess }
            Unmanaged<DisplayStepClock>.fromOpaque(userData).takeUnretainedValue().fire()
            return kCVReturnSuccess
        }, context)
        displayLink = link
        CVDisplayLinkStart(link)
    }

    func stop() {
        if let displayLink {
            CVDisplayLinkStop(displayLink)
        }
        displayLink = nil
    }

    /// Runs on the display link's background thread; hop to main.
    private func fire() {
        DispatchQueue.main.async { [weak self] in self?.onTick() }
    }
}
