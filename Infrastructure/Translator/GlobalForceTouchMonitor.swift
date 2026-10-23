import AppKit
import os

/// 用只监听的 CGEventTap 观察触控板压力事件：一次按压从第一段（普通点按）进入第二段（用力点按）时回调一次。
/// 压力事件属于手势类事件，`NSEvent` 的全局监听收不到，只能经事件流的监听点获取。
/// 只监听不拦截，系统自带的「查询」需由用户在触控板设置中改用其他手势。
@MainActor
final class GlobalForceTouchMonitor: ForceTouchMonitoring {
    /// 未获辅助功能授权时无法创建监听点，按此间隔重试，授权后无需重启 OI。
    private static let retryInterval: Duration = .seconds(2)

    /// 一次按压期间的压力统计，抬起时汇总记录，用于核对实际的段位与压力取值。
    private struct PressStatistics {
        var eventCount = 0
        var maximumStage = 0
        var maximumPressure = 0.0
        var maximumStageTransition = 0.0
    }

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "OI", category: "Translator")
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var retryTask: Task<Void, Never>?
    private var handler: ((CGPoint) -> Void)?
    /// 本次按压是否已触发过：压力来回变化时不重复触发，抬起后复位。
    private var didTriggerInCurrentPress = false
    private var pressStatistics = PressStatistics()

    func start(handler: @escaping (CGPoint) -> Void) {
        stop()
        self.handler = handler
        guard !installTap() else { return }
        logger.notice("Force touch event tap unavailable, retrying until accessibility access is granted")
        retryTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.retryInterval)
                guard let self, !Task.isCancelled else { return }
                if self.installTap() {
                    self.retryTask = nil
                    return
                }
            }
        }
    }

    func stop() {
        retryTask?.cancel()
        retryTask = nil
        removeTap()
        handler = nil
        didTriggerInCurrentPress = false
        pressStatistics = PressStatistics()
    }

    isolated deinit {
        retryTask?.cancel()
        removeTap()
    }

    private func installTap() -> Bool {
        // 事件流中压力事件以手势事件（类型 29 / 30）传递，具体种类记在子类型里，
        // 由 NSEvent(cgEvent:) 还原为 .pressure；只订阅 .pressure 对应的第 34 位收不到。
        let mask = NSEvent.EventTypeMask([.gesture, .magnify, .pressure, .leftMouseUp]).rawValue
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, type, event, userInfo in
                guard let userInfo else { return Unmanaged.passUnretained(event) }
                let monitor = Unmanaged<GlobalForceTouchMonitor>.fromOpaque(userInfo).takeUnretainedValue()
                // 监听源挂在主运行循环上，回调总在主线程。
                MainActor.assumeIsolated {
                    monitor.handle(type: type, event: event)
                }
                return Unmanaged.passUnretained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }

        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        runLoopSource = source
        logger.info("Force touch event tap installed")
        return true
    }

    private func removeTap() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        tap = nil
        runLoopSource = nil
    }

    private func handle(type: CGEventType, event: CGEvent) {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // 系统会停用响应过慢或被用户输入打断的监听点，重新启用即可继续接收。
            if let tap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
        case .leftMouseUp:
            logPressStatistics()
            didTriggerInCurrentPress = false
        default:
            guard let pressureEvent = NSEvent(cgEvent: event), pressureEvent.type == .pressure else { return }
            let stage = pressureEvent.stage
            let pressure = Double(pressureEvent.pressure)
            pressStatistics.eventCount += 1
            pressStatistics.maximumStage = max(pressStatistics.maximumStage, stage)
            pressStatistics.maximumPressure = max(pressStatistics.maximumPressure, pressure)
            pressStatistics.maximumStageTransition = max(
                pressStatistics.maximumStageTransition,
                Double(pressureEvent.stageTransition)
            )
            guard stage > 0 else {
                didTriggerInCurrentPress = false
                return
            }
            // 只认第二段：按住拖选时第一段压力同样会升到接近上限，按压力判断会误触发；
            // 代价是不进入第二段的视图（如备忘录正文）无法用力点按取词。
            guard stage >= 2, !didTriggerInCurrentPress else { return }
            didTriggerInCurrentPress = true
            // 取当前光标位置（全局显示坐标）：手势事件自带的位置字段含义没有文档保证，用力点按时光标不会移动。
            let location = CGEvent(source: nil)?.location ?? event.location
            logger.debug(
                """
                Force click at (\(Double(location.x), privacy: .public), \(Double(location.y), privacy: .public)), \
                stage \(stage, privacy: .public), pressure \(pressure, privacy: .public)
                """
            )
            handler?(location)
        }
    }

    private func logPressStatistics() {
        let statistics = pressStatistics
        pressStatistics = PressStatistics()
        guard statistics.eventCount > 0 else { return }
        logger.debug(
            """
            Press ended: \(statistics.eventCount, privacy: .public) pressure events, \
            max stage \(statistics.maximumStage, privacy: .public), max pressure \(statistics.maximumPressure, privacy: .public), \
            max stage transition \(statistics.maximumStageTransition, privacy: .public)
            """
        )
    }
}
