import Foundation

/// 全局快捷键（呼出启动器、划词翻译、截图翻译）。`modifiers` 采用 Carbon 热键掩码约定
/// （cmdKey = 1 << 8、shiftKey = 1 << 9、optionKey = 1 << 11、controlKey = 1 << 12），
/// 与 `GlobalShortcutHandling` 注册端口一致，本层无需引入 Carbon。
struct GlobalShortcut: Sendable, Equatable, Hashable {
    /// 组合不能用作全局快捷键的原因。
    enum Problem: Sendable, Equatable {
        /// 不含 ⌘、⌥ 或 ⌃：无实质修饰键的全局热键会拦截正常打字。
        case missingModifier
        /// 只用 ⌘（可加 ⇧）配 Space、F 键以外的键：会覆盖所有应用里的同名快捷键（如 ⌘Q、⌘C、⌘W）。
        case overridesAppShortcut
    }

    var keyCode: UInt32
    var modifiers: UInt32

    /// 不能用作全局快捷键的原因；可以使用时为 nil。
    var problem: Problem? {
        let command: UInt32 = 1 << 8
        let optionOrControl: UInt32 = (1 << 11) | (1 << 12)
        if modifiers & (command | optionOrControl) == 0 {
            return .missingModifier
        }
        if modifiers & optionOrControl == 0, !Self.commandOnlyKeyCodes.contains(keyCode) {
            return .overridesAppShortcut
        }
        return nil
    }

    var isValid: Bool { problem == nil }

    /// 只用 ⌘（可加 ⇧）时仍可使用的键：Space 与 F1–F20，各应用一般不拿它们作菜单快捷键。
    /// 取值即 Carbon 的 kVK_Space、kVK_F1…kVK_F20。
    private static let commandOnlyKeyCodes: Set<UInt32> = [
        49,
        122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111,
        105, 107, 113, 106, 64, 79, 80, 90,
    ]

    /// 默认呼出快捷键：Option + Space（keyCode 49 = kVK_Space）。
    static let defaultLauncher = GlobalShortcut(keyCode: 49, modifiers: 1 << 11)

    /// 默认划词翻译快捷键：Option + D（keyCode 2 = kVK_ANSI_D）。
    static let defaultTranslator = GlobalShortcut(keyCode: 2, modifiers: 1 << 11)

    /// 默认截图翻译快捷键：Option + S（keyCode 1 = kVK_ANSI_S），与常见翻译工具「⌥D 划词、⌥S 截图」的习惯一致。
    static let defaultScreenTranslator = GlobalShortcut(keyCode: 1, modifiers: 1 << 11)
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
    var launcherShortcut: GlobalShortcut = .defaultLauncher
    /// Quick AI 接口地址（OpenAI Chat Completions 兼容，如 `https://api.openai.com/v1`）。
    var quickAIBaseURL: String = ""
    /// Quick AI 模型名。API Key 不在此存储，见 `APIKeyStoring`。
    var quickAIModel: String = ""
    /// Quick AI 思考强度，对应接口的 `reasoning_effort` 参数；留空时不发送。
    var quickAIReasoningEffort: String = ""
    /// 触控板用力点按（二段压力）取词翻译。
    var isForceTouchTranslationEnabled: Bool = true
    /// 划词翻译快捷键：翻译选中的文字，未选中时翻译剪贴板。
    var translatorShortcut: GlobalShortcut = .defaultTranslator
    /// 截图翻译快捷键：框选屏幕区域，识别其中的文字并翻译。
    var screenTranslatorShortcut: GlobalShortcut = .defaultScreenTranslator
    /// 翻译目标语言。
    var translationTargetLanguage: TranslationLanguage = .simplifiedChinese
    /// 原文已是目标语言时改译为此语言，默认组合即中文与外文双向互译。
    var translationAlternateLanguage: TranslationLanguage = .english
    /// 划词翻译接口地址，与 Quick AI 分开填写，可以使用不同的服务。
    var translationBaseURL: String = ""
    /// 划词翻译模型名。API Key 同样与 Quick AI 分开存放，见 `APIKeyStoring`。
    var translationModel: String = ""
    /// 划词翻译思考强度，规则同 `quickAIReasoningEffort`。
    var translationReasoningEffort: String = ""
    /// `⌘↩` 网页搜索使用的搜索引擎。
    var webSearchEngine: WebSearchEngine = .bing
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
