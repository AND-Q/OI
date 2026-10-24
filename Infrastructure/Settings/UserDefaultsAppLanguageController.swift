import Foundation

/// 以本应用偏好中的 `AppleLanguages` 指定界面语言，与「系统设置 → 通用 → 语言与地区 → 应用程序」中为单个应用指定语言
/// 是同一个设置，两边的改动互相可见。系统在启动时读取这一偏好，因此改动在重新打开 OI 后生效。
@MainActor
final class UserDefaultsAppLanguageController: AppLanguageControlling {
    private nonisolated static let key = "AppleLanguages"

    private let defaults: UserDefaults
    /// 本应用自己的偏好域：读合并后的值会混入系统的语言列表，分不清是否单独指定过语言。
    private let domainName: String
    /// 系统的首选语言（不含为 OI 单独指定的语言），用于判断跟随系统时界面使用的语言。
    private let systemLanguages: [String]

    init(
        defaults: UserDefaults = .standard,
        domainName: String = Bundle.main.bundleIdentifier ?? "OI",
        systemLanguages: [String] = UserDefaultsAppLanguageController.systemPreferredLanguages()
    ) {
        self.defaults = defaults
        self.domainName = domainName
        self.systemLanguages = systemLanguages
    }

    /// 全局偏好中的首选语言，即「系统设置 → 通用 → 语言与地区」中的语言列表。
    nonisolated static func systemPreferredLanguages() -> [String] {
        UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)?[key] as? [String] ?? []
    }

    /// OI 只提供简体中文与英文界面，在系统设置中为 OI 指定的也只会是这两种之一；其他取值按跟随系统处理。
    var language: AppLanguage {
        guard let preferred = (defaults.persistentDomain(forName: domainName)?[Self.key] as? [String])?.first else {
            return .system
        }
        if preferred.hasPrefix("zh") { return .simplifiedChinese }
        if preferred.hasPrefix("en") { return .english }
        return .system
    }

    func setLanguage(_ language: AppLanguage) {
        switch language {
        case .system:
            defaults.removeObject(forKey: Self.key)
        case .simplifiedChinese, .english:
            defaults.set([language.rawValue], forKey: Self.key)
        }
    }

    /// 跟随系统时同系统为应用选定界面语言：按首选语言的顺序取第一个 OI 提供的语言，繁体中文不会改用简体；
    /// 都没有时为开发语言英文。
    func interfaceLanguage(for language: AppLanguage) -> AppLanguage {
        guard language == .system else { return language }
        for identifier in systemLanguages {
            let preferred = Locale.Language(identifier: identifier)
            if preferred.languageCode == .english {
                return .english
            }
            // `zh-CN`、`zh-SG` 等不写书写系统的标识按地区补全后再判断。
            if preferred.languageCode == .chinese,
               Locale.Language(identifier: preferred.maximalIdentifier).script == .hanSimplified {
                return .simplifiedChinese
            }
        }
        return .english
    }
}
