import Foundation

/// UserDefaults 持久化的应用设置。缺失的键回退到 `AppSettings` 默认值，
/// 保证首次启动或旧版本升级后的行为与既有版本一致。
@MainActor
final class UserDefaultsAppSettingsStore: AppSettingsStoring {
    private static let silentLaunchKey = "settings.isSilentLaunchEnabled"
    private static let fileSearchKey = "settings.isFileSearchEnabled"
    private static let usageRankingKey = "settings.isUsageRankingEnabled"
    private static let shortcutKeyCodeKey = "settings.launcherShortcut.keyCode"
    private static let shortcutModifiersKey = "settings.launcherShortcut.modifiers"
    private static let quickAIBaseURLKey = "settings.quickAI.baseURL"
    private static let quickAIModelKey = "settings.quickAI.model"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> AppSettings {
        let fallback = AppSettings()
        // 快捷键两个键视为整体：仅保存其一时按未配置处理；外部写入的脏数据
        // （负数、越界、无修饰键的非法组合）一律回退默认，避免启动崩溃或
        // 注册出拦截正常输入的全局热键。
        let rawKeyCode = defaults.object(forKey: Self.shortcutKeyCodeKey) as? Int
        let rawModifiers = defaults.object(forKey: Self.shortcutModifiersKey) as? Int
        let launcherShortcut: LauncherShortcut
        if let rawKeyCode, let rawModifiers,
           let keyCode = UInt32(exactly: rawKeyCode),
           let modifiers = UInt32(exactly: rawModifiers) {
            let loaded = LauncherShortcut(keyCode: keyCode, modifiers: modifiers)
            launcherShortcut = loaded.isValid ? loaded : fallback.launcherShortcut
        } else {
            launcherShortcut = fallback.launcherShortcut
        }
        return AppSettings(
            isSilentLaunchEnabled: defaults.object(forKey: Self.silentLaunchKey) as? Bool
                ?? fallback.isSilentLaunchEnabled,
            isFileSearchEnabled: defaults.object(forKey: Self.fileSearchKey) as? Bool
                ?? fallback.isFileSearchEnabled,
            isUsageRankingEnabled: defaults.object(forKey: Self.usageRankingKey) as? Bool
                ?? fallback.isUsageRankingEnabled,
            launcherShortcut: launcherShortcut,
            quickAIBaseURL: defaults.string(forKey: Self.quickAIBaseURLKey) ?? fallback.quickAIBaseURL,
            quickAIModel: defaults.string(forKey: Self.quickAIModelKey) ?? fallback.quickAIModel
        )
    }

    func save(_ settings: AppSettings) {
        defaults.set(settings.isSilentLaunchEnabled, forKey: Self.silentLaunchKey)
        defaults.set(settings.isFileSearchEnabled, forKey: Self.fileSearchKey)
        defaults.set(settings.isUsageRankingEnabled, forKey: Self.usageRankingKey)
        defaults.set(Int(settings.launcherShortcut.keyCode), forKey: Self.shortcutKeyCodeKey)
        defaults.set(Int(settings.launcherShortcut.modifiers), forKey: Self.shortcutModifiersKey)
        defaults.set(settings.quickAIBaseURL, forKey: Self.quickAIBaseURLKey)
        defaults.set(settings.quickAIModel, forKey: Self.quickAIModelKey)
    }
}
