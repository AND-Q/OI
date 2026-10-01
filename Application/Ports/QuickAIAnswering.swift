import Foundation

/// 一次 Quick AI 请求所需的接口配置（OpenAI Chat Completions 兼容接口）。
struct QuickAIConfiguration: Sendable, Equatable {
    let baseURL: URL
    let model: String
    /// 本地服务（如 Ollama）无需鉴权时为 nil。
    let apiKey: String?

    /// 接口地址须为带主机名的 http(s) 绝对地址、模型名非空，否则视为未配置；
    /// 未写协议头时自动补全（见 `addingDefaultScheme`）；空白 API Key 按未提供处理。
    init?(baseURLString: String, model: String, apiKey: String?) {
        let trimmedURL = Self.addingDefaultScheme(
            to: baseURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        )
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

    /// 漏写协议头时补全：本机与局域网地址（多为 Ollama 等本地服务）补 `http://`，其余补 `https://`。
    /// 已写协议头（包括不支持的协议）时原样返回，交由上面的校验处理。
    static func addingDefaultScheme(to urlString: String) -> String {
        guard !urlString.isEmpty, !urlString.contains("://") else { return urlString }
        let host = urlString.prefix { $0 != "/" && $0 != ":" }.lowercased()
        let isLocal = host == "localhost" || host == "0.0.0.0" || host.hasSuffix(".local")
            || host.hasPrefix("127.") || host.hasPrefix("10.") || host.hasPrefix("192.168.")
        return (isLocal ? "http://" : "https://") + urlString
    }
}

/// 流式问答端口：按到达顺序逐段产出回答文本增量。
/// `systemPrompt` 由用例给出（Quick AI 问答与划词翻译各有指令）；取消消费方任务即中断底层请求。
protocol QuickAIAnswering: Sendable {
    func streamAnswer(
        to question: String,
        systemPrompt: String,
        configuration: QuickAIConfiguration
    ) -> AsyncThrowingStream<String, Error>
}
