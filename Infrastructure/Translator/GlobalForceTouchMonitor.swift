import AppKit
import os

/// 用只监听的 CGEventTap 观察触控板压力事件：一次按压从第一段（普通点按）进入第二段（用力点按）时回调一次。
/// 压力事件属于手势类事件，`NSEvent` 的全局监听收不到，只能经事件流的监听点获取。
/// 只监听不拦截，系统自带的「查询」需由用户在触控板设置中改用其他手势。
@MainActor
final class GlobalForceTouchMonitor: ForceTouchMonitoring {
    /// 未获辅助功能授权时无法创建监听点，按此间隔重试，授权后无需重启 OI。
    private static let retryInterval: Duration = .seconds(2)

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "OI", category: "Translator")
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var retryTask: Task<Void, Never>?
    private var handler: ((CGPoint) -> Void)?
    /// 本次按压是否已触发过：压力在一、二段之间来回时不重复触发，抬起后复位。
    private var didTriggerInCurrentPress = false

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
    }

    isolated deinit {
        retryTask?.cancel()
        removeTap()
    }

    private func installTap() -> Bool {
        let mask = NSEvent.EventTypeMask.pressure.union(.leftMouseUp).rawValue
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
            didTriggerInCurrentPress = false
        default:
            guard let pressureEvent = NSEvent(cgEvent: event), pressureEvent.type == .pressure else { return }
            guard pressureEvent.stage > 0 else {
                didTriggerInCurrentPress = false
                return
            }
            guard pressureEvent.stage >= 2, !didTriggerInCurrentPress else { return }
            didTriggerInCurrentPress = true
            let location = event.location
            logger.debug(
                "Force click at (\(Double(location.x), privacy: .public), \(Double(location.y), privacy: .public))"
            )
            handler?(location)
        }
    }
}
