import CoreGraphics
import Foundation

/// 取到的待翻译文字。`screenRect` 采用全局显示坐标（原点在主屏左上角、y 轴向下，
/// 与辅助功能 API 和 CGEvent 一致）；目标应用不提供文字位置时为 nil。
struct CapturedText: Equatable, Sendable {
    enum Source: Equatable, Sendable {
        /// 其他应用中选中的文字。
        case selection
        /// 用力点按位置下的单词。
        case word
        /// 系统剪贴板。
        case clipboard
        /// 截图翻译中框选的屏幕区域里识别出的文字。
        case screen
    }

    let text: String
    let source: Source
    let screenRect: CGRect?

    /// 单次最多取用的字符数，避免全选长文档时把整篇内容发送出去。
    static let maximumLength = 5000

    /// 待翻译的文字：去掉首尾空白并截断过长的内容；只剩空白时为 nil。取词、剪贴板与截图识字共用。
    static func cleaned(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(maximumLength))
    }
}

/// 按坐标取词的结果。
enum WordLookup: Equatable, Sendable {
    /// 点按处的单词。
    case found(CapturedText)
    /// 点按处不是可取的文字：应用提供了文字位置但点按处没有单词（空白、标点），
    /// 或是密码框、OI 自身的窗口。不应再改用其他方式取词。
    case notOnText
    /// 应用没有提供该处的文字位置，无法判断，可改用其他方式取词。
    case unavailable
}

/// 读取其他应用中的文字（辅助功能 API）与剪贴板。辅助功能查询是对目标进程的同步 IPC，
/// 目标应用卡顿时可能阻塞，实现须在后台执行，异步方法不得占用主线程。
protocol TextCapturing: Sendable {
    /// 前台应用中选中的文字；未选中、目标应用不提供或未获授权时为 nil。
    func selectedText() async -> CapturedText?
    /// `point`（全局显示坐标）处的取词结果。
    func word(at point: CGPoint) async -> WordLookup
    /// 剪贴板中的纯文本；被标记为敏感（如密码管理器复制的密码）的内容不读取。
    @MainActor func clipboardText() -> CapturedText?
}
