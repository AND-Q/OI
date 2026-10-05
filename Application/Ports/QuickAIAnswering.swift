import Foundation

/// 一次 Quick AI 请求所需的接口配置（OpenAI Chat Completions 兼容接口）。
struct QuickAIConfiguration: Sendable, Equatable {
    let baseURL: URL
    let model: String
    /// 本地服务（如 Ollama）无需鉴权时为 nil。
    let apiKey: String?
    /// 思考强度（`reasoning_effort`），各服务支持的取值不同；未填写时为 nil，请求中不发送。
    let reasoningEffort: String?

    /// 接口地址须为带主机名的 http(s) 绝对地址、模型名非空，否则视为未配置；
    /// 未写协议头时自动补全（见 `addingDefaultScheme`）；空白 API Key 与思考强度按未提供处理。
    init?(baseURLString: String, model: String, apiKey: String?, reasoningEffort: String? = nil) {
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
        let trimmedEffort = reasoningEffort?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.reasoningEffort = trimmedEffort.isEmpty ? nil : trimmedEffort
    }

    /// 漏写协议头时补全：本机与局域网地址（多为 Ollama 等本地服务）补 `http://`，其余补 `https://`。
    /// 已写协议头（包括不支持的协议）时原样返回，交由上面的校验处理。
    static func addingDefaultScheme(to urlString: String) -> String {
        guard !urlString.isEmpty, !urlString.contains("://") else { return urlString }
        return (isLocalHost(hostPart(of: urlString)) ? "http://" : "https://") + urlString
    }

    /// 未写协议头的地址中的主机名：IPv6 写在方括号里（`[::1]:11434`），其余取到第一个 `/` 或 `:` 为止。
    private static func hostPart(of urlString: String) -> String {
        if urlString.hasPrefix("["), let end = urlString.firstIndex(of: "]") {
            return String(urlString[urlString.index(after: urlString.startIndex)..<end]).lowercased()
        }
        return urlString.prefix { $0 != "/" && $0 != ":" }.lowercased()
    }

    /// 接口地址是否经 http 访问本机与局域网以外的主机：此时 API Key、提问与翻译原文都明文经过公网。
    /// 未写协议头的公网地址会补 `https://`，不算明文。
    static func isPlaintextOverPublicNetwork(baseURLString: String) -> Bool {
        let urlString = addingDefaultScheme(to: baseURLString.trimmingCharacters(in: .whitespacesAndNewlines))
        guard let url = URL(string: urlString),
              url.scheme?.lowercased() == "http",
              let host = url.host()?.lowercased(), !host.isEmpty else { return false }
        return !isLocalHost(host)
    }

    /// 本机与局域网地址，多为 Ollama 等本地服务：localhost、`.local` 主机名，IPv4 本机、私有与链路本地网段
    /// （127/8、10/8、172.16/12、192.168/16、169.254/16），IPv6 本机、链路本地与唯一本地地址（::1、fe80::/10、fc00::/7）。
    private static func isLocalHost(_ host: String) -> Bool {
        let host = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if ["localhost", "0.0.0.0", "::1"].contains(host) || host.hasSuffix(".local") {
            return true
        }
        if host.contains(":") {
            return ["fe8", "fe9", "fea", "feb", "fc", "fd"].contains { host.hasPrefix($0) }
        }
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        let octets = parts.compactMap { UInt8($0) }
        guard parts.count == 4, octets.count == 4 else { return false }
        switch (octets[0], octets[1]) {
        case (127, _), (10, _), (172, 16...31), (192, 168), (169, 254):
            return true
        default:
            return false
        }
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
