import Foundation

/// 全局快捷键（呼出启动器、划词翻译）。`modifiers` 采用 Carbon 热键掩码约定
/// （cmdKey = 1 << 8、shiftKey = 1 << 9、optionKey = 1 << 11、controlKey = 1 << 12），
/// 与 `GlobalShortcutHandling` 注册端口一致，本层无需引入 Carbon。
struct LauncherShortcut: Sendable, Equatable, Hashable {
    var keyCode: UInt32
    var modifiers: UInt32

    /// 组合必须包含 ⌘、⌥ 或 ⌃ 之一：无实质修饰键的全局热键会拦截正常打字。
    var isValid: Bool {
        let actionableModifiers: UInt32 = (1 << 8) | (1 << 11) | (1 << 12)
        return modifiers & actionableModifiers != 0
    }

    /// 默认呼出快捷键：Option + Space（keyCode 49 = kVK_Space）。
    static let standard = LauncherShortcut(keyCode: 49, modifiers: 1 << 11)

    /// 默认划词翻译快捷键：Option + D（keyCode 2 = kVK_ANSI_D）。
    static let standardTranslator = LauncherShortcut(keyCode: 2, modifiers: 1 << 11)
}

/// 应用级用户设置（设置面板读写）。开机自启动不在此存储：其状态由系统登录项持有，
/// 设置面板实时读取，见 `LoginItemControlling`。
struct AppSettings: Sendable, Equatable {
    /// 开机静默启动：启动时仅驻留菜单栏，不自动呼出启动器面板。
    var isSilentLaunchEnabled: Bool = true
    /// Spotlight 文件与文件夹搜索。
    var isFileSearchEnabled: Bool = true
    /// 启动历史排序：记录启动次数与最近使用时间，优化常用应用排序。
    var isUsageRankingEnabled: Bool = true
    /// 全局呼出快捷键。
    var launcherShortcut: LauncherShortcut = .standard
    /// Quick AI 接口地址（OpenAI Chat Completions 兼容，如 `https://api.openai.com/v1`）。
    var quickAIBaseURL: String = ""
    /// Quick AI 模型名。API Key 不在此存储，见 `QuickAIKeyStoring`。
    var quickAIModel: String = ""
    /// 触控板用力点按（二段压力）取词翻译。
    var isForceTouchTranslationEnabled: Bool = true
    /// 划词翻译快捷键：翻译选中的文字，未选中时翻译剪贴板。
    var translatorShortcut: LauncherShortcut = .standardTranslator
    /// 翻译目标语言。
    var translationTargetLanguage: TranslationLanguage = .simplifiedChinese
    /// 原文已是目标语言时改译为此语言，默认组合即中文与外文双向互译。
    var translationAlternateLanguage: TranslationLanguage = .english
}

/// 应用级设置的持久化端口。设置值极小且只在主线程读写，端口按同步设计。
@MainActor
protocol AppSettingsStoring: AnyObject {
    func load() -> AppSettings
    func save(_ settings: AppSettings)
}

/// 用作默认实现和测试用的内存存储；不做任何持久化。
@MainActor
final class MemoryAppSettingsStore: AppSettingsStoring {
    private var storedSettings: AppSettings

    init(initial: AppSettings = AppSettings()) {
        storedSettings = initial
    }

    func load() -> AppSettings {
        storedSettings
    }

    func save(_ settings: AppSettings) {
        storedSettings = settings
    }
}
