import Foundation

/// OI 的界面语言：跟随系统，或单独指定（同「系统设置 → 通用 → 语言与地区 → 应用程序」中为单个应用指定语言）。
/// `rawValue` 为指定时使用的语言代码。
enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case system
    case simplifiedChinese = "zh-Hans"
    case english = "en"

    var id: String { rawValue }
}

/// 界面语言的端口。设置值由系统持有（本应用的语言偏好），设置面板实时读取；改动在重新打开 OI 后生效。
@MainActor
protocol AppLanguageControlling: AnyObject {
    var language: AppLanguage { get }
    func setLanguage(_ language: AppLanguage)
    /// 选择 `language` 时界面实际使用的语言（简体中文或英文）：跟随系统时按系统的首选语言选定。
    func interfaceLanguage(for language: AppLanguage) -> AppLanguage
}

/// 用作默认实现和测试用的内存实现；不影响实际的界面语言。
@MainActor
final class MemoryAppLanguageController: AppLanguageControlling {
    private(set) var language: AppLanguage
    /// 跟随系统时界面使用的语言。
    private let systemLanguage: AppLanguage

    init(language: AppLanguage = .system, systemLanguage: AppLanguage = .simplifiedChinese) {
        self.language = language
        self.systemLanguage = systemLanguage
    }

    func setLanguage(_ language: AppLanguage) {
        self.language = language
    }

    func interfaceLanguage(for language: AppLanguage) -> AppLanguage {
        language == .system ? systemLanguage : language
    }
}
