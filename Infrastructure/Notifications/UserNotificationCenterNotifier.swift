import os
import UserNotifications

/// 经系统通知中心发出提示。第一次需要提示时才请求通知权限，从未出错的用户不会被打扰；
/// 用户未允许时只记日志。OI 自身处于前台时也以横幅展示：如应用没能启动，前台仍是 OI。
@MainActor
final class UserNotificationCenterNotifier: NSObject, UserNotifying {
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "OI", category: "Notification")

    func notify(title: String, body: String) {
        let center = UNUserNotificationCenter.current()
        // 通知中心只弱引用代理，本对象由依赖图持有。
        center.delegate = self
        let logger = self.logger
        // 回调在后台队列执行，只捕获可跨线程的值，通知内容在回调中现建。
        center.requestAuthorization(options: [.alert]) { @Sendable granted, _ in
            guard granted else {
                logger.notice("Notification not authorized: \(title, privacy: .public)")
                return
            }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
            UNUserNotificationCenter.current().add(request) { @Sendable error in
                guard let error else { return }
                logger.error("Notification failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}

extension UserNotificationCenterNotifier: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list]
    }
}
