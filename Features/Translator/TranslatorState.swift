import CoreGraphics
import Foundation

/// 一次划词翻译：原文（可在气泡中修改）、语言方向与流式到达的译文。
struct TranslatorSession: Equatable, Sendable {
    enum State: Equatable, Sendable {
        /// 截图翻译正在识别选区中的文字，尚无原文。
        case recognizing
        /// 原文已修改、尚未翻译。
        case draft
        case streaming
        case finished
        case failed(String)
    }

    /// 回车在当前状态下的作用，面板按键与页脚提示共用同一判断。
    enum ReturnAction: Equatable, Sendable {
        case none
        case translate
        case copyAndClose
        case retry
    }

    /// 每次取词生成新的会话标识，界面据此重置原文编辑等临时状态。
    let id = UUID()
    var sourceText: String
    let source: CapturedText.Source
    var sourceLanguageCode: String?
    var targetLanguage: TranslationLanguage
    /// 用户在气泡中手动选过目标语言：修改原文后重新翻译仍沿用该语言。
    var isTargetLanguagePinned = false
    var translation = ""
    var state: State = .streaming
    /// 复制后在页脚给出反馈；译文继续增长时复位。
    var isCopied = false

    var isStreaming: Bool { state == .streaming }

    /// 展示与复制的译文：去掉推理模型输出在开头的思考内容。
    var visibleTranslation: String {
        QuickAIMarkdown.removingThinking(from: translation)
    }

    /// 待翻译时翻译（原文为空则不响应）；识别与输出期间不响应；失败或没有译文时重试；否则复制并关闭。
    var returnAction: ReturnAction {
        switch state {
        case .draft:
            sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .none : .translate
        case .recognizing, .streaming:
            .none
        case .failed:
            .retry
        case .finished:
            visibleTranslation.isEmpty ? .retry : .copyAndClose
        }
    }

    /// 原文语言的展示名：支持的语言使用统一译名，其余交给系统的本地化语言名；无法识别时为 nil。
    var sourceLanguageName: String? {
        guard let sourceLanguageCode else { return nil }
        if let language = TranslationLanguage(languageCode: sourceLanguageCode) {
            return language.displayName
        }
        return Locale(identifier: "zh-Hans").localizedString(forLanguageCode: sourceLanguageCode)
    }
}

/// 翻译气泡中需要用户注意的情况。
enum TranslatorNotice: Equatable, Sendable {
    /// 未获辅助功能权限，读不到选中的文字，已改为翻译剪贴板。
    case clipboardUsedWithoutAccessibility
    /// 未获辅助功能权限，剪贴板中也没有文字。
    case accessibilityRequired
    /// 没有选中的文字，剪贴板中也没有文字。
    case nothingToTranslate
    /// 未获屏幕录制权限，无法截图翻译。
    case screenRecordingRequired
    /// 截图翻译的选区中没有识别到文字。
    case noTextInSelection
    /// 截图翻译截取屏幕或识别文字失败。
    case screenCaptureFailed
}

/// 气泡的展示位置：`anchorRect` 为原文所在区域（全局显示坐标），为 nil 时贴着鼠标指针弹出。
struct TranslatorPresentation: Equatable, Sendable {
    let anchorRect: CGRect?
}

/// 按下截图翻译快捷键的结果。
enum ScreenTranslationStart: Sendable {
    /// 已定格屏幕画面，进入框选。
    case selection(ScreenSnapshot)
    /// 只弹出提示：未获屏幕录制权限或截屏失败。
    case notice
}
