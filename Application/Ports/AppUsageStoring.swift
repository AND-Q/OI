import Foundation

/// 按应用持久化的启动统计（搜索计划 §9）。
struct AppUsageRecord: Codable, Sendable, Equatable {
    var launchCount: Int
    var lastLaunchedAt: Date?
}

/// 启动历史的持久化端口。键是应用的 usage key
/// （bundle identifier，缺失时回退到 descriptor id）。
protocol AppUsageStoring: Sendable {
    func records() async -> [String: AppUsageRecord]
    func recordLaunch(key: String) async
    func prune(keeping keys: [String]) async
}

/// 用作默认实现和测试用的内存存储；不做任何持久化。
actor MemoryAppUsageStore: AppUsageStoring {
    private var storedRecords: [String: AppUsageRecord] = [:]
    private let now: () -> Date

    init(now: @escaping () -> Date = { Date() }) {
        self.now = now
    }

    func records() -> [String: AppUsageRecord] {
        storedRecords
    }

    func recordLaunch(key: String) {
        var record = storedRecords[key] ?? AppUsageRecord(launchCount: 0, lastLaunchedAt: nil)
        record.launchCount += 1
        record.lastLaunchedAt = now()
        storedRecords[key] = record
    }

    func prune(keeping keys: [String]) {
        let keep = Set(keys)
        storedRecords = storedRecords.filter { keep.contains($0.key) }
    }
}
