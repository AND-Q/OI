import Foundation

/// 基于 OpenAI Chat Completions 流式接口（SSE）的问答实现，以及查询可用模型（`GET /models`），
/// 兼容 OpenAI、Ollama（`/v1`）及各类兼容网关。
struct OpenAICompatibleAIClient: AIAnswering, AIModelListing {
    /// 两次收到数据之间最长的等待（不是整次回答的总时长）：本机大模型首次加载可能一分钟以上
    /// 才开始输出，放宽到 3 分钟；等不及时按 Esc 中断。
    static let idleTimeout: TimeInterval = 180
    /// 查询模型列表的超时：只是读一份列表，等太久说明地址或网络有问题。
    static let modelListTimeout: TimeInterval = 15

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func streamAnswer(
        to question: String,
        systemPrompt: String,
        configuration: AIEndpointConfiguration
    ) -> AsyncThrowingStream<String, Error> {
        let request = Self.makeRequest(
            question: question,
            systemPrompt: systemPrompt,
            configuration: configuration
        )
        let session = self.session
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (bytes, response) = try await session.bytes(for: request)
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                    guard (200..<300).contains(status) else {
                        // 错误响应体通常是一小段 JSON，只读前 4KB 用于提取原因。
                        var body = Data()
                        for try await byte in bytes {
                            body.append(byte)
                            if body.count >= 4096 { break }
                        }
                        throw AIClientError.httpStatus(status, Self.errorMessage(from: body))
                    }
                    for try await line in bytes.lines {
                        switch Self.parseStreamLine(line) {
                        case .delta(let text):
                            continuation.yield(text)
                        case .done:
                            continuation.finish()
                            return
                        case .failure(let message):
                            throw AIClientError.server(message)
                        case .ignored:
                            continue
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            // 消费方取消（Esc、面板隐藏）时立即中断网络请求。
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func models(baseURL: URL, apiKey: String?) async throws -> [String] {
        var request = URLRequest(url: Self.modelsURL(for: baseURL))
        request.timeoutInterval = Self.modelListTimeout
        // 用户刚在服务端开通或下载了模型时要拿到最新的列表。
        request.cachePolicy = .reloadIgnoringLocalCacheData
        if let apiKey {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        let result: (Data, URLResponse)
        do {
            result = try await session.data(for: request)
        } catch let error as URLError where error.code != .cancelled {
            throw AIModelListError.unreachable(error.localizedDescription)
        }
        let (data, response) = result
        return try Self.modelIDs(from: data, status: (response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    /// 模型列表地址：接口地址后接 `models`；填的是完整的 chat/completions 地址时先去掉这两段。
    static func modelsURL(for baseURL: URL) -> URL {
        let trimmedPath = baseURL.path().trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard trimmedPath.hasSuffix("chat/completions") else {
            return baseURL.appending(path: "models")
        }
        return baseURL.deletingLastPathComponent().deletingLastPathComponent().appending(path: "models")
    }

    /// 按状态码解析模型列表（`{"data":[{"id":…}]}`，OpenAI 与 Ollama 相同），模型 ID 去重并按名称排序。
    static func modelIDs(from data: Data, status: Int) throws -> [String] {
        switch status {
        case 200..<300:
            guard let payload = try? JSONDecoder().decode(ModelListPayload.self, from: data) else {
                throw AIModelListError.invalidResponse
            }
            return Set(payload.data.map(\.id)).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        case 401, 403:
            throw AIModelListError.unauthorized(status)
        case 404:
            throw AIModelListError.notFound
        default:
            throw AIModelListError.httpStatus(status, errorMessage(from: data))
        }
    }

    static func endpointURL(for baseURL: URL) -> URL {
        let trimmedPath = baseURL.path().trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if trimmedPath.hasSuffix("chat/completions") {
            if baseURL.absoluteString.hasSuffix("/") {
                return URL(string: String(baseURL.absoluteString.dropLast())) ?? baseURL
            }
            return baseURL
        }
        return baseURL.appending(path: "chat/completions")
    }

    static func makeRequest(
        question: String,
        systemPrompt: String,
        configuration: AIEndpointConfiguration
    ) -> URLRequest {
        // 用户可能直接粘贴完整的 chat/completions 地址，此时不再重复拼接。
        let endpoint = endpointURL(for: configuration.baseURL)
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = idleTimeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        if let apiKey = configuration.apiKey {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        let body = RequestBody(
            model: configuration.model,
            messages: [
                .init(role: "system", content: systemPrompt),
                .init(role: "user", content: question),
            ],
            stream: true,
            reasoningEffort: configuration.reasoningEffort
        )
        request.httpBody = try? JSONEncoder().encode(body)
        return request
    }

    enum StreamEvent: Equatable {
        case delta(String)
        case done
        case failure(String)
        case ignored
    }

    /// 解析一行 SSE：只关心 `data:` 行，`[DONE]` 表示结束；注释、心跳与无内容的块忽略。
    static func parseStreamLine(_ line: String) -> StreamEvent {
        guard line.hasPrefix("data:") else { return .ignored }
        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        if payload == "[DONE]" { return .done }
        guard let data = payload.data(using: .utf8),
              let chunk = try? JSONDecoder().decode(StreamChunk.self, from: data) else { return .ignored }
        if let message = chunk.error?.message { return .failure(message) }
        if let content = chunk.choices?.first?.delta?.content, !content.isEmpty {
            return .delta(content)
        }
        return .ignored
    }

    /// 从错误响应体提取可读原因：兼容 OpenAI `{"error":{"message":…}}`
    /// 与 Ollama `{"error":"…"}`，都不是时截取原文。
    static func errorMessage(from body: Data) -> String? {
        if let envelope = try? JSONDecoder().decode(ErrorEnvelope.self, from: body),
           let message = envelope.error?.message {
            return message
        }
        let text = String(decoding: body, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : String(text.prefix(200))
    }
}

enum AIClientError: LocalizedError, Equatable {
    case httpStatus(Int, String?)
    case server(String)

    var errorDescription: String? {
        switch self {
        case .httpStatus(let status, let message?):
            "服务返回 \(status)：\(message)"
        case .httpStatus(let status, nil):
            "服务返回 \(status)"
        case .server(let message):
            message
        }
    }
}

/// 查询模型列表失败的原因，提示用户该检查地址、Key 还是网络。
enum AIModelListError: LocalizedError, Equatable {
    case unreachable(String)
    case unauthorized(Int)
    case notFound
    case httpStatus(Int, String?)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .unreachable(let reason):
            "无法连接到接口地址：\(reason)"
        case .unauthorized(let status):
            "API Key 无效或没有权限（\(status)）"
        case .notFound:
            "接口地址不正确，或该服务不支持查询模型列表（404）"
        case .httpStatus(let status, let message?):
            "服务返回 \(status)：\(message)"
        case .httpStatus(let status, nil):
            "服务返回 \(status)"
        case .invalidResponse:
            "无法识别服务返回的模型列表"
        }
    }
}

private struct ModelListPayload: Decodable {
    struct Model: Decodable {
        let id: String
    }

    let data: [Model]
}

private struct RequestBody: Encodable {
    struct Message: Encodable {
        let role: String
        let content: String
    }

    let model: String
    let messages: [Message]
    let stream: Bool
    /// 为 nil 时整个字段不编码：不支持该参数的服务可能直接拒绝请求。
    let reasoningEffort: String?

    private enum CodingKeys: String, CodingKey {
        case model
        case messages
        case stream
        case reasoningEffort = "reasoning_effort"
    }
}

private struct StreamChunk: Decodable {
    struct Choice: Decodable {
        struct Delta: Decodable {
            let content: String?
        }

        let delta: Delta?
    }

    let choices: [Choice]?
    let error: ErrorPayload?
}

private struct ErrorEnvelope: Decodable {
    let error: ErrorPayload?
}

/// `error` 字段既可能是字符串也可能是带 message 的对象。
private struct ErrorPayload: Decodable {
    let message: String?

    private enum CodingKeys: String, CodingKey {
        case message
    }

    init(from decoder: Decoder) throws {
        if let text = try? decoder.singleValueContainer().decode(String.self) {
            message = text
        } else {
            message = try decoder.container(keyedBy: CodingKeys.self)
                .decodeIfPresent(String.self, forKey: .message)
        }
    }
}
