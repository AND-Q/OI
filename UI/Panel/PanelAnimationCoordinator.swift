import AppKit
import QuartzCore

/// 启动器面板所有窗口几何动画的唯一驱动者，仿照原生聚焦搜索的 `WindowAnimationCoordinator`：
/// 与垂直同步的时钟在每次屏幕刷新时步进窗口尺寸，SwiftUI 内容跟随发布的几何尺寸，
/// 因此面板与内容不会错位。
@MainActor
final class PanelAnimationCoordinator: ObservableObject {
    private enum Layout {
        /// 面板与菜单栏之间的距离，按参考显示器校准。
        static let topGap: CGFloat = 156
        /// 临界阻尼弹簧的响应时间；越小越干脆。
        static let resizeResponse: TimeInterval = 0.20
        static let fadeInDuration: TimeInterval = 0.08
        static let fadeOutDuration: TimeInterval = 0.10
        /// 剩余距离小到察觉不出时直接到位并结束。
        static let settleDistance: CGFloat = 0.5
    }

    /// SwiftUI 内容渲染所用的高度；每帧重新发布。
    @Published private(set) var currentHeight: CGFloat
    private(set) var cornerRadius: CGFloat

    /// 面板所在的显示器；面板显示或重新确定屏幕时由持有者设置，调整尺寸时不会跳到其他显示器。
    var screen: NSScreen?

    private let panel: NSPanel
    private let reduceMotion: @MainActor () -> Bool
    private var clock: DisplayStepClock?
    private var resizeState: (
        start: CGFloat,
        target: CGFloat,
        startRadius: CGFloat,
        targetRadius: CGFloat,
        startTime: CFTimeInterval,
        initialVelocity: CGFloat
    )?
    private var currentVelocity: CGFloat = 0
    private var alphaState: (
        from: CGFloat, to: CGFloat, startTime: CFTimeInterval, duration: TimeInterval, completion: (() -> Void)?
    )?
    private var isDismissing = false
    /// 用户拖动过面板（只有 Quick AI 模式下能拖动，见 LauncherView）：左上角留在放下的位置，
    /// 高度变化时向下伸缩。每次呼出面板时复位，不记忆拖动后的位置。
    private var isMoved = false
    /// 正在由 OI 自己设置面板几何：期间的移动通知不是用户拖动。
    private var isApplyingFrame = false
    private var moveObservers: [any NSObjectProtocol] = []

    /// 持有者释放时若动画仍在进行，打破时钟与 CADisplayLink 目标之间的循环引用。
    isolated deinit {
        clock?.stop()
        for observer in moveObservers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    init(
        panel: NSPanel,
        initialHeight: CGFloat,
        reduceMotion: @escaping @MainActor () -> Bool = {
            NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        }
    ) {
        self.panel = panel
        self.reduceMotion = reduceMotion
        self.currentHeight = initialHeight
        let radius = Self.cornerRadius(forHeight: initialHeight)
        self.cornerRadius = radius
        updateLayerCornerRadius(radius)
        moveObservers = [NSWindow.willMoveNotification, NSWindow.didMoveNotification].map { name in
            NotificationCenter.default.addObserver(forName: name, object: panel, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.panelDidMove()
                }
            }
        }
    }

    var isDismissalInProgress: Bool { isDismissing }
    var targetHeight: CGFloat { resizeState?.target ?? currentHeight }

    /// 收起时为胶囊圆角，展开时为展开圆角。
    static func cornerRadius(forHeight height: CGFloat) -> CGFloat {
        height <= LauncherLayout.searchHeight + 0.5
            ? LauncherLayout.compactCornerRadius
            : LauncherLayout.expandedCornerRadius
    }

    /// 面板顶边与水平中心固定，高度向下增长，与原生聚焦搜索面板一致。
    static func frame(for screen: NSScreen?, height: CGFloat) -> NSRect {
        let visibleFrame = screen?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        return frame(
            topLeft: NSPoint(x: visibleFrame.midX - LauncherLayout.width / 2, y: visibleFrame.maxY - Layout.topGap),
            height: height,
            within: visibleFrame
        )
    }

    /// 左上角固定在 `topLeft`，高度向下增长；超出屏幕可见区域的上下边缘时整体移回区域内。
    private static func frame(topLeft: NSPoint, height: CGFloat, within visibleFrame: NSRect) -> NSRect {
        let y = topLeft.y - height
        let clampedY = max(visibleFrame.minY, min(y, visibleFrame.maxY - height))
        return NSRect(
            x: topLeft.x.rounded(),
            y: clampedY.rounded(),
            width: LauncherLayout.width,
            height: height.rounded()
        )
    }

    /// 面板在 `height` 下的位置：拖动过时左上角留在放下的位置（按当前位置计算，拖动途中调整高度也不会跳回），
    /// 否则为默认位置。
    func frame(forHeight height: CGFloat) -> NSRect {
        guard isMoved, let visibleFrame = (panel.screen ?? screen)?.visibleFrame else {
            return Self.frame(for: screen, height: height)
        }
        return Self.frame(
            topLeft: NSPoint(x: panel.frame.minX, y: panel.frame.maxY),
            height: height,
            within: visibleFrame
        )
    }

    /// 把面板放回 `screen` 上的默认位置并清除拖动记录；每次呼出面板时调用。
    func moveToDefaultPosition(height: CGFloat) {
        isMoved = false
        setPanelFrame(Self.frame(for: screen, height: height), display: true)
    }

    /// OI 自己设置面板几何都经过这里，期间的移动通知不算用户拖动。
    func setPanelFrame(_ frame: NSRect, display: Bool) {
        isApplyingFrame = true
        panel.setFrame(frame, display: display)
        isApplyingFrame = false
    }

    /// 放弃进行中的过渡，立即采用 `height`。
    func prepareForPresentation(height: CGFloat) {
        stopAnimations()
        currentHeight = height
        currentVelocity = 0
        let radius = Self.cornerRadius(forHeight: height)
        cornerRadius = radius
        updateLayerCornerRadius(radius)
    }

    /// 把窗口伸缩到 `height`；中途改变目标时保留当前速度。
    func resize(toHeight height: CGFloat) {
        guard height != targetHeight else { return }

        // 输入可能在第一次屏幕刷新之前就被清空：即使窗口仍是收起高度，也要取消待进行的展开。
        if reduceMotion() || height == currentHeight {
            resizeState = nil
            applyGeometry(height: height, radius: Self.cornerRadius(forHeight: height))
            return
        }

        let initialVelocity = (resizeState != nil) ? currentVelocity : 0
        resizeState = (
            start: currentHeight,
            target: height,
            startRadius: cornerRadius,
            targetRadius: Self.cornerRadius(forHeight: height),
            startTime: CACurrentMediaTime(),
            initialVelocity: initialVelocity
        )
        ensureClock()
    }

    /// 面板移到最前之后淡入。
    func fadeIn() {
        if reduceMotion() {
            alphaState = nil
            panel.alphaValue = 1
            return
        }
        panel.alphaValue = 0
        alphaState = (from: 0, to: 1, startTime: CACurrentMediaTime(), duration: Layout.fadeInDuration, completion: nil)
        ensureClock()
    }

    /// 淡出面板，完全透明后移出屏幕。
    func fadeOutAndOrderOut() {
        if reduceMotion() {
            stopAnimations()
            panel.orderOut(nil)
            panel.alphaValue = 1
            return
        }
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

    /// 撤销进行中的淡出：从当前透明度淡入回来，而不是从完全透明重新开始。
    func cancelDismissal() {
        guard isDismissing else { return }
        isDismissing = false
        if reduceMotion() {
            alphaState = nil
            panel.alphaValue = 1
            return
        }
        alphaState = (
            from: panel.alphaValue,
            to: 1,
            startTime: CACurrentMediaTime(),
            duration: Layout.fadeInDuration,
            completion: nil
        )
        ensureClock()
    }

    /// 取消所有进行中的动画，不产生其他副作用。
    func stopAnimations() {
        clock?.stop()
        clock = nil
        resizeState = nil
        alphaState = nil
        currentVelocity = 0
        isDismissing = false
    }

    private func ensureClock() {
        guard clock == nil else { return }
        let clock = DisplayStepClock(window: panel) { [weak self] in self?.step() }
        self.clock = clock
        clock.start()
    }

    private func step() {
        // 动画进行中也遵从「减弱动态效果」设置的变化。
        if reduceMotion() {
            if let resize = resizeState {
                resizeState = nil
                applyGeometry(height: resize.target, radius: resize.targetRadius)
            }
            if let alpha = alphaState {
                alphaState = nil
                panel.alphaValue = alpha.to
                alpha.completion?()
            }
            clock?.stop()
            clock = nil
            return
        }

        let now = CACurrentMediaTime()
        var isBusy = false

        if let resize = resizeState {
            let elapsed = now - resize.startTime
            let (height, velocity) = Self.evaluateSpring(
                elapsed: elapsed,
                start: resize.start,
                target: resize.target,
                initialVelocity: resize.initialVelocity,
                response: Layout.resizeResponse
            )
            currentVelocity = velocity

            let radiusSettled = Self.springSettledFraction(elapsed: elapsed, response: Layout.resizeResponse)
            let radius = resize.startRadius + (resize.targetRadius - resize.startRadius) * radiusSettled

            if height != currentHeight { currentHeight = height }
            cornerRadius = radius

            CATransaction.begin()
            CATransaction.setDisableActions(true)
            setPanelFrame(frame(forHeight: height), display: false)
            setLayerCornerRadius(radius)
            CATransaction.commit()

            if (abs(resize.target - height) < Layout.settleDistance && abs(velocity) < 15.0)
                || elapsed > Layout.resizeResponse * 3 {
                applyGeometry(height: resize.target, radius: resize.targetRadius)
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

    private func applyGeometry(height: CGFloat, radius: CGFloat) {
        currentHeight = height
        cornerRadius = radius
        currentVelocity = 0
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        setPanelFrame(frame(forHeight: height), display: false)
        updateLayerCornerRadius(radius)
        CATransaction.commit()
    }

    /// 移动通知不是来自 OI 自己设置面板几何时，即用户拖动了面板。
    private func panelDidMove() {
        guard !isApplyingFrame, panel.isVisible, !isDismissing else { return }
        isMoved = true
    }

    /// 每帧只更新圆角。阴影刻意不在动画循环中重算：`invalidateShadow` 会让 WindowServer
    /// 按窗口透明度重建阴影，以屏幕刷新率执行代价太高。
    private func setLayerCornerRadius(_ radius: CGFloat) {
        guard let surface = panel.contentView as? LauncherPanelSurface else { return }
        if surface.cornerRadius != radius { surface.updateCornerRadius(radius) }
    }

    /// 由原生玻璃表面决定轮廓。只在几何过渡结束时重算窗口阴影，从不逐帧重算。
    private func updateLayerCornerRadius(_ radius: CGFloat) {
        setLayerCornerRadius(radius)
        panel.invalidateShadow()
    }

    /// 带初速度的临界阻尼弹簧：
    /// 微分方程：x'' + 2*omega0*x' + omega0^2 * x = 0，其中 x(t) = y(t) - target。
    /// 解析解：
    /// x(t) = (x0 + c2 * t) * exp(-omega0 * t)，其中 x0 = start - target，c2 = v0 + omega0 * x0。
    /// y(t) = target + x(t)
    /// v(t) = (v0 - omega0 * c2 * t) * exp(-omega0 * t)
    static func evaluateSpring(
        elapsed: TimeInterval,
        start: CGFloat,
        target: CGFloat,
        initialVelocity: CGFloat,
        response: TimeInterval
    ) -> (position: CGFloat, velocity: CGFloat) {
        guard elapsed > 0 else { return (start, initialVelocity) }
        let omega0 = 6.0 / response
        let x0 = start - target
        let c2 = initialVelocity + omega0 * x0
        let decay = exp(-omega0 * elapsed)
        let position = target + (x0 + c2 * CGFloat(elapsed)) * CGFloat(decay)
        let velocity = (initialVelocity - omega0 * c2 * CGFloat(elapsed)) * CGFloat(decay)
        return (position, velocity)
    }

    private static func springSettledFraction(elapsed: TimeInterval, response: TimeInterval) -> CGFloat {
        let x = elapsed * 6.0 / response
        return CGFloat(1 - (1 + x) * exp(-x))
    }
}

/// 与垂直同步的步进时钟：经 `CADisplayLink` 在每次屏幕刷新时调用一次 `onTick`。
/// 与面板窗口所在的屏幕同步并在主线程回调，原生支持 ProMotion 与刷新率不同的多显示器。
@MainActor
private final class DisplayStepClock {
    private let onTick: @MainActor () -> Void
    private weak var window: NSWindow?
    private var displayLink: CADisplayLink?

    init(window: NSWindow, onTick: @escaping @MainActor () -> Void) {
        self.window = window
        self.onTick = onTick
    }

    isolated deinit {
        stop()
    }

    func start() {
        guard displayLink == nil, let window, window.isVisible else { return }
        let link = window.displayLink(target: self, selector: #selector(stepLink(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    func stop() {
        if let displayLink {
            displayLink.remove(from: .main, forMode: .common)
            displayLink.invalidate()
            self.displayLink = nil
        }
    }

    /// CADisplayLink 回调：与面板所在屏幕的刷新同步调用。
    @objc private func stepLink(_ sender: CADisplayLink) {
        onTick()
    }
}
