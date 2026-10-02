import Foundation

/// Quick AI 问答与划词翻译共用的流式请求：按当前设置组装接口配置，逐段转交增量，
/// 并把底层错误换成应用层错误。
@MainActor
struct QuickAIStreaming {
    private let answerer: any QuickAIAnswering
    private let settingsStore: any AppSettingsStoring
    private let keyStore: any QuickAIKeyStoring

    init(
        answerer: any QuickAIAnswering,
        settingsStore: any AppSettingsStoring,
        keyStore: any QuickAIKeyStoring
    ) {
        self.answerer = answerer
        self.settingsStore = settingsStore
        self.keyStore = keyStore
    }

    /// 以 `systemPrompt` 为指令发送 `text`，并把增量逐段交给 `onDelta`。
    /// 接口地址或模型缺失时不发起请求，直接抛出未配置错误。
    func stream(_ text: String, systemPrompt: String, onDelta: (String) -> Void) async throws {
        let settings = settingsStore.load()
        guard let configuration = QuickAIConfiguration(
            baseURLString: settings.quickAIBaseURL,
            model: settings.quickAIModel,
            apiKey: keyStore.load()
        ) else {
            throw ApplicationError.quickAINotConfigured
        }

        do {
            for try await delta in answerer.streamAnswer(
                to: text,
                systemPrompt: systemPrompt,
                configuration: configuration
            ) {
                onDelta(delta)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ApplicationError.quickAIFailed(
                reason: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            )
        }
    }
}
