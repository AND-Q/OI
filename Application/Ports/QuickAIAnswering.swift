import Foundation

/// 一次 Quick AI 请求所需的接口配置（OpenAI Chat Completions 兼容接口）。
struct QuickAIConfiguration: Sendable, Equatable {
    let baseURL: URL
    let model: String
    /// 本地服务（如 Ollama）无需鉴权时为 nil。
    let apiKey: String?

    /// 接口地址须为带主机名的 http(s) 绝对地址、模型名非空，否则视为未配置；
    /// 空白 API Key 按未提供处理。
    init?(baseURLString: String, model: String, apiKey: String?) {
        let trimmedURL = baseURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmedURL),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host() != nil,
              !trimmedModel.isEmpty else { return nil }
        let trimmedKey = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.baseURL = url
        self.model = trimmedModel
        self.apiKey = trimmedKey.isEmpty ? nil : trimmedKey
    }
}

/// 流式问答端口：按到达顺序逐段产出回答文本增量。
/// 取消消费方任务即中断底层请求。
protocol QuickAIAnswering: Sendable {
    func streamAnswer(
        to question: String,
        configuration: QuickAIConfiguration
    ) -> AsyncThrowingStream<String, Error>
}
