import Foundation

@MainActor
struct AskQuickAI {
    static let systemPrompt =
        "你是 macOS 启动器里的快速问答助手。请直接、简洁地回答，使用与提问相同的语言，需要时使用 Markdown。"

    private let streaming: AIStreaming

    init(
        answerer: any AIAnswering,
        settingsStore: any AppSettingsStoring,
        keyStore: any APIKeyStoring
    ) {
        streaming = AIStreaming(
            answerer: answerer,
            settingsStore: settingsStore,
            keyStore: keyStore,
            baseURL: \.quickAIBaseURL,
            model: \.quickAIModel,
            reasoningEffort: \.quickAIReasoningEffort
        )
    }

    /// 按当前设置发起提问，并把回答增量逐段交给 `onDelta`。
    /// 接口地址或模型缺失时不发起请求，直接抛出未配置错误。
    func execute(question: String, onDelta: (String) -> Void) async throws {
        try await streaming.stream(question, systemPrompt: Self.systemPrompt, onDelta: onDelta)
    }
}
