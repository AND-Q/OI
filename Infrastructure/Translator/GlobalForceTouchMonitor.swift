import AppKit

/// 用全局事件监听观察触控板压力事件：一次按压从第一段（普通点按）进入第二段（用力点按）时回调一次。
/// 全局监听只能观察、不能拦截事件，系统自带的「查询」需由用户在触控板设置中改用其他手势。
@MainActor
final class GlobalForceTouchMonitor: ForceTouchMonitoring {
    private var monitor: Any?
    private var handler: ((CGPoint) -> Void)?
    /// 本次按压是否已触发过：压力在一、二段之间来回时不重复触发，抬起后复位。
    private var didTriggerInCurrentPress = false

    func start(handler: @escaping (CGPoint) -> Void) {
        stop()
        self.handler = handler
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.pressure, .leftMouseUp]) { [weak self] event in
            self?.handle(event)
        }
    }

    func stop() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
        handler = nil
        didTriggerInCurrentPress = false
    }

    isolated deinit {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
    }

    private func handle(_ event: NSEvent) {
        guard event.type == .pressure, event.stage > 0 else {
            didTriggerInCurrentPress = false
            return
        }
        guard event.stage >= 2, !didTriggerInCurrentPress,
              let location = CGEvent(source: nil)?.location else { return }
        didTriggerInCurrentPress = true
        handler?(location)
    }
}
