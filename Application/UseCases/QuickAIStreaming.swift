import Foundation

/// Quick AI 问答与划词翻译共用的流式请求：按当前设置组装接口配置，逐段转交增量，
/// 并把底层错误换成应用层错误。两者的接口各自填写，`baseURL`、`model`、`reasoningEffort` 与 `keyStore`
/// 指明读取哪一组。
@MainActor
struct QuickAIStreaming {
    private let answerer: any QuickAIAnswering
    private let settingsStore: any AppSettingsStoring
    private let keyStore: any QuickAIKeyStoring
    private let baseURL: KeyPath<AppSettings, String>
    private let model: KeyPath<AppSettings, String>
    private let reasoningEffort: KeyPath<AppSettings, String>

    init(
        answerer: any QuickAIAnswering,
        settingsStore: any AppSettingsStoring,
        keyStore: any QuickAIKeyStoring,
        baseURL: KeyPath<AppSettings, String>,
        model: KeyPath<AppSettings, String>,
        reasoningEffort: KeyPath<AppSettings, String>
    ) {
        self.answerer = answerer
        self.settingsStore = settingsStore
        self.keyStore = keyStore
        self.baseURL = baseURL
        self.model = model
        self.reasoningEffort = reasoningEffort
    }

    /// 以 `systemPrompt` 为指令发送 `text`，并把增量逐段交给 `onDelta`。
    /// 接口地址或模型缺失时不发起请求，直接抛出未配置错误。
    func stream(_ text: String, systemPrompt: String, onDelta: (String) -> Void) async throws {
        let settings = settingsStore.load()
        guard let configuration = QuickAIConfiguration(
            baseURLString: settings[keyPath: baseURL],
            model: settings[keyPath: model],
            apiKey: keyStore.load(),
            reasoningEffort: settings[keyPath: reasoningEffort]
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
