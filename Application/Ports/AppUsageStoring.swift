import Foundation

/// Launch statistics persisted per application (search plan §9).
struct AppUsageRecord: Codable, Sendable, Equatable {
    var launchCount: Int
    var lastLaunchedAt: Date?
}

/// Persistence port for launch history. Keys are the application usage key
/// (bundle identifier, falling back to the descriptor id).
protocol AppUsageStoring: Sendable {
    func records() async -> [String: AppUsageRecord]
    func recordLaunch(key: String) async
    func prune(keeping keys: [String]) async
}

/// In-memory store used as the default and in tests; persists nothing.
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
