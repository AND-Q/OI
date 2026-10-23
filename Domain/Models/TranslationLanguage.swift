import Foundation

/// 划词翻译支持的目标语言。`rawValue` 为 BCP-47 语言代码，用于与语种识别结果对照。
enum TranslationLanguage: String, CaseIterable, Identifiable, Sendable {
    case simplifiedChinese = "zh-Hans"
    case traditionalChinese = "zh-Hant"
    case english = "en"
    case japanese = "ja"
    case korean = "ko"
    case french = "fr"
    case german = "de"
    case spanish = "es"
    case italian = "it"
    case portuguese = "pt"
    case russian = "ru"
    case vietnamese = "vi"
    case thai = "th"
    case arabic = "ar"

    var id: String { rawValue }

    /// 设置面板与翻译气泡中展示的名称。
    var displayName: String {
        switch self {
        case .simplifiedChinese: String(localized: "简体中文")
        case .traditionalChinese: String(localized: "繁体中文")
        case .english: String(localized: "英语")
        case .japanese: String(localized: "日语")
        case .korean: String(localized: "韩语")
        case .french: String(localized: "法语")
        case .german: String(localized: "德语")
        case .spanish: String(localized: "西班牙语")
        case .italian: String(localized: "意大利语")
        case .portuguese: String(localized: "葡萄牙语")
        case .russian: String(localized: "俄语")
        case .vietnamese: String(localized: "越南语")
        case .thai: String(localized: "泰语")
        case .arabic: String(localized: "阿拉伯语")
        }
    }

    /// 写进模型提示词的英文名：英文语言名对各类模型（含本地小模型）最稳定。
    var promptName: String {
        switch self {
        case .simplifiedChinese: "Simplified Chinese"
        case .traditionalChinese: "Traditional Chinese"
        case .english: "English"
        case .japanese: "Japanese"
        case .korean: "Korean"
        case .french: "French"
        case .german: "German"
        case .spanish: "Spanish"
        case .italian: "Italian"
        case .portuguese: "Portuguese"
        case .russian: "Russian"
        case .vietnamese: "Vietnamese"
        case .thai: "Thai"
        case .arabic: "Arabic"
        }
    }

    /// 把识别出的语言代码对应到支持的语言：先精确匹配（区分简繁），再按主语言匹配。
    init?(languageCode: String) {
        if let exact = Self(rawValue: languageCode) {
            self = exact
            return
        }
        guard let match = Self.allCases.first(where: { $0.isSameLanguage(as: languageCode) }) else {
            return nil
        }
        self = match
    }

    /// 系统或界面的首选语言（如 `zh-Hans-CN`、`zh-TW`、`en-US`）对应的语言；中文按书写系统区分简繁。
    init?(preferredLanguage identifier: String) {
        let language = Locale.Language(identifier: identifier)
        guard language.languageCode == .chinese else {
            guard let match = Self(languageCode: identifier) else { return nil }
            self = match
            return
        }
        // `zh-TW`、`zh-HK` 等不写书写系统的标识按地区补全后再判断。
        let script = Locale.Language(identifier: language.maximalIdentifier).script
        self = script == .hanTraditional ? .traditionalChinese : .simplifiedChinese
    }

    /// 没有保存过翻译语言时的默认组合：外文译为首选语言，原文已是首选语言时译为英语；首选语言是英语时改译为简体中文，
    /// 不支持的首选语言按英语处理。中文系统即「外文译简体中文、中文译英语」。
    static func defaultPair(
        preferredLanguages: [String]
    ) -> (target: TranslationLanguage, alternate: TranslationLanguage) {
        let target = preferredLanguages.first.flatMap(TranslationLanguage.init(preferredLanguage:)) ?? .english
        return (target, target == .english ? .simplifiedChinese : .english)
    }

    /// 按主语言比较：简繁中文同属中文，`pt-BR` 与葡萄牙语视为同一语言。
    func isSameLanguage(as languageCode: String) -> Bool {
        Self.primarySubtag(of: languageCode) == Self.primarySubtag(of: rawValue)
    }

    private static func primarySubtag(of languageCode: String) -> String {
        let subtag = languageCode.split(whereSeparator: { $0 == "-" || $0 == "_" }).first
        return subtag.map { $0.lowercased() } ?? languageCode.lowercased()
    }
}
