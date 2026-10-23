import Foundation

/// 持久化到 UserDefaults 的启动历史（搜索计划 §9）。读写在本 actor 上进行，
/// 不占用调用方的执行器，不会卡住面板。
actor UserDefaultsAppUsageStore: AppUsageStoring {
    private static let storageKey = "applicationUsageRecords.v1"

    private let defaults: UserDefaults
    private let now: () -> Date

    init(defaults: UserDefaults = .standard, now: @escaping () -> Date = { Date() }) {
        self.defaults = defaults
        self.now = now
    }

    func records() -> [String: AppUsageRecord] {
        guard let data = defaults.data(forKey: Self.storageKey),
              let decoded = try? JSONDecoder().decode([String: AppUsageRecord].self, from: data)
        else { return [:] }
        return decoded
    }

    func recordLaunch(key: String) {
        var allRecords = records()
        var record = allRecords[key] ?? AppUsageRecord(launchCount: 0, lastLaunchedAt: nil)
        record.launchCount += 1
        record.lastLaunchedAt = now()
        allRecords[key] = record
        persist(allRecords)
    }

    func prune(keeping keys: [String]) {
        let keep = Set(keys)
        let allRecords = records()
        let filtered = allRecords.filter { keep.contains($0.key) }
        if filtered.count != allRecords.count {
            persist(filtered)
        }
    }

    private func persist(_ records: [String: AppUsageRecord]) {
        guard let data = try? JSONEncoder().encode(records) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }
}
