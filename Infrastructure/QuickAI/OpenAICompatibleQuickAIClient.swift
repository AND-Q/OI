import Foundation

/// 基于 OpenAI Chat Completions 流式接口（SSE）的问答实现，
/// 兼容 OpenAI、Ollama（`/v1`）及各类兼容网关。
struct OpenAICompatibleQuickAIClient: QuickAIAnswering {
    static let systemPrompt =
        "你是 macOS 启动器里的快速问答助手。请直接、简洁地回答，使用与提问相同的语言，需要时使用 Markdown。"

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func streamAnswer(
        to question: String,
        configuration: QuickAIConfiguration
    ) -> AsyncThrowingStream<String, Error> {
        let request = Self.makeRequest(question: question, configuration: configuration)
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
                        throw QuickAIClientError.httpStatus(status, Self.errorMessage(from: body))
                    }
                    for try await line in bytes.lines {
                        switch Self.parseStreamLine(line) {
                        case .delta(let text):
                            continuation.yield(text)
                        case .done:
                            continuation.finish()
                            return
                        case .failure(let message):
                            throw QuickAIClientError.server(message)
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

    static func makeRequest(question: String, configuration: QuickAIConfiguration) -> URLRequest {
        // 用户可能直接粘贴完整的 chat/completions 地址，此时不再重复拼接。
        let endpoint = configuration.baseURL.path().hasSuffix("chat/completions")
            ? configuration.baseURL
            : configuration.baseURL.appending(path: "chat/completions")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
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
            stream: true
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

enum QuickAIClientError: LocalizedError, Equatable {
    case httpStatus(Int, String?)
    case server(String)

    var errorDescription: String? {
        switch self {
        case .httpStatus(let status, let message?):
            return "服务返回 \(status)：\(message)"
        case .httpStatus(let status, nil):
            return "服务返回 \(status)"
        case .server(let message):
            return message
        }
    }
}

private struct RequestBody: Encodable {
    struct Message: Encodable {
        let role: String
        let content: String
    }

    let model: String
    let messages: [Message]
    let stream: Bool
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
