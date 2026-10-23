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
    private static let quickAIReasoningEffortKey = "settings.quickAI.reasoningEffort"
    private static let forceTouchTranslationKey = "settings.translator.isForceTouchEnabled"
    private static let translatorShortcutKeyCodeKey = "settings.translator.shortcut.keyCode"
    private static let translatorShortcutModifiersKey = "settings.translator.shortcut.modifiers"
    private static let screenTranslatorShortcutKeyCodeKey = "settings.translator.screenShortcut.keyCode"
    private static let screenTranslatorShortcutModifiersKey = "settings.translator.screenShortcut.modifiers"
    private static let translationTargetLanguageKey = "settings.translator.targetLanguage"
    private static let translationAlternateLanguageKey = "settings.translator.alternateLanguage"
    private static let translationBaseURLKey = "settings.translator.baseURL"
    private static let translationModelKey = "settings.translator.model"
    private static let translationReasoningEffortKey = "settings.translator.reasoningEffort"
    private static let webSearchEngineKey = "settings.webSearchEngine"

    private let defaults: UserDefaults
    /// 首选语言（界面语言在前），决定没有保存过翻译语言时的默认组合。
    private let preferredLanguages: [String]

    init(defaults: UserDefaults = .standard, preferredLanguages: [String] = Locale.preferredLanguages) {
        self.defaults = defaults
        self.preferredLanguages = preferredLanguages
    }

    func load() -> AppSettings {
        let fallback = AppSettings()
        let quickAIBaseURL = defaults.string(forKey: Self.quickAIBaseURLKey) ?? fallback.quickAIBaseURL
        let quickAIModel = defaults.string(forKey: Self.quickAIModelKey) ?? fallback.quickAIModel
        // 翻译语言的默认值随首选语言：中文系统与 `AppSettings` 的默认相同，英文系统默认外文译英语、英文译简体中文。
        let defaultLanguages = TranslationLanguage.defaultPair(preferredLanguages: preferredLanguages)
        return AppSettings(
            isSilentLaunchEnabled: defaults.object(forKey: Self.silentLaunchKey) as? Bool
                ?? fallback.isSilentLaunchEnabled,
            isFileSearchEnabled: defaults.object(forKey: Self.fileSearchKey) as? Bool
                ?? fallback.isFileSearchEnabled,
            isUsageRankingEnabled: defaults.object(forKey: Self.usageRankingKey) as? Bool
                ?? fallback.isUsageRankingEnabled,
            launcherShortcut: loadShortcut(
                keyCodeKey: Self.shortcutKeyCodeKey,
                modifiersKey: Self.shortcutModifiersKey
            ) ?? fallback.launcherShortcut,
            quickAIBaseURL: quickAIBaseURL,
            quickAIModel: quickAIModel,
            quickAIReasoningEffort: defaults.string(forKey: Self.quickAIReasoningEffortKey)
                ?? fallback.quickAIReasoningEffort,
            isForceTouchTranslationEnabled: defaults.object(forKey: Self.forceTouchTranslationKey) as? Bool
                ?? fallback.isForceTouchTranslationEnabled,
            translatorShortcut: loadShortcut(
                keyCodeKey: Self.translatorShortcutKeyCodeKey,
                modifiersKey: Self.translatorShortcutModifiersKey
            ) ?? fallback.translatorShortcut,
            screenTranslatorShortcut: loadShortcut(
                keyCodeKey: Self.screenTranslatorShortcutKeyCodeKey,
                modifiersKey: Self.screenTranslatorShortcutModifiersKey
            ) ?? fallback.screenTranslatorShortcut,
            translationTargetLanguage: loadLanguage(forKey: Self.translationTargetLanguageKey)
                ?? defaultLanguages.target,
            translationAlternateLanguage: loadLanguage(forKey: Self.translationAlternateLanguageKey)
                ?? defaultLanguages.alternate,
            // 旧版本的划词翻译与 Quick AI 共用接口：从未保存过翻译接口时沿用 Quick AI 的值，
            // 升级后翻译照常可用；下次保存设置时写入，此后两者各自独立。
            translationBaseURL: defaults.string(forKey: Self.translationBaseURLKey) ?? quickAIBaseURL,
            translationModel: defaults.string(forKey: Self.translationModelKey) ?? quickAIModel,
            translationReasoningEffort: defaults.string(forKey: Self.translationReasoningEffortKey)
                ?? fallback.translationReasoningEffort,
            webSearchEngine: defaults.string(forKey: Self.webSearchEngineKey)
                .flatMap(WebSearchEngine.init(rawValue:)) ?? fallback.webSearchEngine
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
        defaults.set(settings.quickAIReasoningEffort, forKey: Self.quickAIReasoningEffortKey)
        defaults.set(settings.isForceTouchTranslationEnabled, forKey: Self.forceTouchTranslationKey)
        defaults.set(Int(settings.translatorShortcut.keyCode), forKey: Self.translatorShortcutKeyCodeKey)
        defaults.set(Int(settings.translatorShortcut.modifiers), forKey: Self.translatorShortcutModifiersKey)
        defaults.set(Int(settings.screenTranslatorShortcut.keyCode), forKey: Self.screenTranslatorShortcutKeyCodeKey)
        defaults.set(Int(settings.screenTranslatorShortcut.modifiers), forKey: Self.screenTranslatorShortcutModifiersKey)
        defaults.set(settings.translationTargetLanguage.rawValue, forKey: Self.translationTargetLanguageKey)
        defaults.set(settings.translationAlternateLanguage.rawValue, forKey: Self.translationAlternateLanguageKey)
        defaults.set(settings.translationBaseURL, forKey: Self.translationBaseURLKey)
        defaults.set(settings.translationModel, forKey: Self.translationModelKey)
        defaults.set(settings.translationReasoningEffort, forKey: Self.translationReasoningEffortKey)
        defaults.set(settings.webSearchEngine.rawValue, forKey: Self.webSearchEngineKey)
    }

    /// 快捷键两个键视为整体：仅保存其一时按未配置处理；外部写入的脏数据
    /// （负数、越界、不能用作全局快捷键的组合）一律回退默认，避免启动崩溃或
    /// 注册出拦截正常输入、覆盖各应用同名快捷键的全局热键。
    private func loadShortcut(keyCodeKey: String, modifiersKey: String) -> GlobalShortcut? {
        guard let rawKeyCode = defaults.object(forKey: keyCodeKey) as? Int,
              let rawModifiers = defaults.object(forKey: modifiersKey) as? Int,
              let keyCode = UInt32(exactly: rawKeyCode),
              let modifiers = UInt32(exactly: rawModifiers) else { return nil }
        let shortcut = GlobalShortcut(keyCode: keyCode, modifiers: modifiers)
        return shortcut.isValid ? shortcut : nil
    }

    /// 未知的语言代码（如旧版本写入、手工改动）按未配置处理。
    private func loadLanguage(forKey key: String) -> TranslationLanguage? {
        defaults.string(forKey: key).flatMap(TranslationLanguage.init(rawValue:))
    }
}
