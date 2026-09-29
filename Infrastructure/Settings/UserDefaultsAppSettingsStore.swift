import Foundation

/// UserDefaults 持久化的应用设置。缺失的键回退到 `AppSettings` 默认值，
/// 保证首次启动或旧版本升级后的行为与既有版本一致。
@MainActor
final class UserDefaultsAppSettingsStore: AppSettingsStoring {
    private static let silentLaunchKey = "settings.isSilentLaunchEnabled"
    private static let fileSearchKey = "settings.isFileSearchEnabled"
    private static let usageRankingKey = "settings.isUsageRankingEnabled"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> AppSettings {
        let fallback = AppSettings()
        return AppSettings(
            isSilentLaunchEnabled: defaults.object(forKey: Self.silentLaunchKey) as? Bool
                ?? fallback.isSilentLaunchEnabled,
            isFileSearchEnabled: defaults.object(forKey: Self.fileSearchKey) as? Bool
                ?? fallback.isFileSearchEnabled,
            isUsageRankingEnabled: defaults.object(forKey: Self.usageRankingKey) as? Bool
                ?? fallback.isUsageRankingEnabled
        )
    }

    func save(_ settings: AppSettings) {
        defaults.set(settings.isSilentLaunchEnabled, forKey: Self.silentLaunchKey)
        defaults.set(settings.isFileSearchEnabled, forKey: Self.fileSearchKey)
        defaults.set(settings.isUsageRankingEnabled, forKey: Self.usageRankingKey)
    }
}
