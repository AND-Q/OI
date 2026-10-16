import Foundation

/// 经系统通知中心提示用户的应用层端口：用于面板已经收起后才得知的结果，如后台打开应用失败。
@MainActor
protocol UserNotifying: AnyObject {
    func notify(title: String, body: String)
}

/// 用作默认实现和测试用的记录器；不发出系统通知，只按顺序记下每条提示。
@MainActor
final class MemoryUserNotifier: UserNotifying {
    struct Record: Equatable {
        let title: String
        let body: String
    }

    private(set) var records: [Record] = []

    func notify(title: String, body: String) {
        records.append(Record(title: title, body: body))
    }
}
