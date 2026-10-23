import Foundation

/// 设置面板的「获取模型」与「测试连接」：按填写的接口地址与 API Key 查询服务提供的模型。
/// 用的是面板上当前的输入（API Key 可能还没保存到钥匙串），因此由调用方直接传入，不读设置存储。
struct ListAIModels: Sendable {
    private let lister: any AIModelListing

    init(lister: any AIModelListing) {
        self.lister = lister
    }

    /// 接口地址无效时不发请求，直接抛出未配置错误；空白 API Key 按未提供处理；其余失败统一换成带原因的应用层错误。
    func execute(baseURLString: String, apiKey: String) async throws -> [String] {
        guard let baseURL = AIEndpointConfiguration.baseURL(from: baseURLString) else {
            throw ApplicationError.aiNotConfigured
        }
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            return try await lister.models(baseURL: baseURL, apiKey: trimmedKey.isEmpty ? nil : trimmedKey)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ApplicationError.aiRequestFailed(
                reason: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            )
        }
    }
}
