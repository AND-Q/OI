import Foundation

/// 查询 AI 接口提供的模型（OpenAI 兼容接口的 `GET /models`），用于设置面板的「获取模型」与「测试连接」。
protocol AIModelListing: Sendable {
    /// `baseURL` 下可用的模型 ID，已去重并按名称排序；`apiKey` 为 nil 时不带鉴权（如本机的 Ollama）。
    /// 服务不可达、API Key 无效或地址不对时抛出带原因的错误。
    func models(baseURL: URL, apiKey: String?) async throws -> [String]
}
