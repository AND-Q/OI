import Foundation

@MainActor
struct AskQuickAI {
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

    /// 按当前设置发起提问，并把回答增量逐段交给 `onDelta`。
    /// 接口地址或模型缺失时不发起请求，直接抛出未配置错误。
    func execute(question: String, onDelta: (String) -> Void) async throws {
        let settings = settingsStore.load()
        guard let configuration = QuickAIConfiguration(
            baseURLString: settings.quickAIBaseURL,
            model: settings.quickAIModel,
            apiKey: keyStore.load()
        ) else {
            throw ApplicationError.quickAINotConfigured
        }

        do {
            for try await delta in answerer.streamAnswer(to: question, configuration: configuration) {
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
