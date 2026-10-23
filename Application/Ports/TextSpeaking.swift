import Foundation

/// 发音朗读端口：用系统的语音合成在本机朗读，不调用网络接口。同一时间只朗读一段，开始新的朗读即停止正在进行的。
@MainActor
protocol TextSpeaking: AnyObject {
    /// 用 `languageCode`（BCP-47，如 `en`、`zh-Hans`）对应的发音人朗读 `text`；读完、被新的朗读取代或任务取消时返回，
    /// 取消即停止朗读。语言为 nil 或本机没有该语言的发音人时用系统默认的发音人。
    func speak(_ text: String, languageCode: String?) async
}
