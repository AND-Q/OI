import Foundation

/// 语种识别端口。
protocol LanguageDetecting: Sendable {
    /// 文本主要语言的 BCP-47 代码（如 `en`、`zh-Hans`）；无法判断时为 nil。
    func dominantLanguageCode(of text: String) -> String?
}
