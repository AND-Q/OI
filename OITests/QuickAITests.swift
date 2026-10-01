import Foundation
import XCTest

@testable import OI

@MainActor
final class QuickAITests: XCTestCase {
    // MARK: - Configuration

    func testConfigurationRequiresHTTPURLAndModel() {
        XCTAssertNil(QuickAIConfiguration(baseURLString: "", model: "gpt", apiKey: nil))
        XCTAssertNil(QuickAIConfiguration(baseURLString: "api.openai.com/v1", model: "gpt", apiKey: nil))
        XCTAssertNil(QuickAIConfiguration(baseURLString: "ftp://example.com", model: "gpt", apiKey: nil))
        XCTAssertNil(QuickAIConfiguration(baseURLString: "https://api.openai.com/v1", model: "  ", apiKey: nil))

        let configuration = QuickAIConfiguration(
            baseURLString: " http://localhost:11434/v1 ",
            model: " qwen2.5 ",
            apiKey: "  "
        )
        XCTAssertEqual(configuration?.baseURL.absoluteString, "http://localhost:11434/v1")
        XCTAssertEqual(configuration?.model, "qwen2.5")
        XCTAssertNil(configuration?.apiKey)
    }

    // MARK: - OpenAI compatible client

    func testParseStreamLineExtractsDeltaDoneAndErrors() {
        typealias Client = OpenAICompatibleQuickAIClient
        XCTAssertEqual(
            Client.parseStreamLine(#"data: {"choices":[{"delta":{"content":"你好"}}]}"#),
            .delta("你好")
        )
        XCTAssertEqual(Client.parseStreamLine("data: [DONE]"), .done)
        XCTAssertEqual(
            Client.parseStreamLine(#"data: {"error":{"message":"rate limited"}}"#),
            .failure("rate limited")
        )
        XCTAssertEqual(Client.parseStreamLine(#"data: {"choices":[{"delta":{"role":"assistant"}}]}"#), .ignored)
        XCTAssertEqual(Client.parseStreamLine(": keep-alive"), .ignored)
        XCTAssertEqual(Client.parseStreamLine("data: not json"), .ignored)
    }

    func testErrorMessageSupportsOpenAIAndOllamaShapes() {
        typealias Client = OpenAICompatibleQuickAIClient
        XCTAssertEqual(
            Client.errorMessage(from: Data(#"{"error":{"message":"Incorrect API key"}}"#.utf8)),
            "Incorrect API key"
        )
        XCTAssertEqual(
            Client.errorMessage(from: Data(#"{"error":"model not found"}"#.utf8)),
            "model not found"
        )
        XCTAssertEqual(Client.errorMessage(from: Data("Bad Gateway".utf8)), "Bad Gateway")
        XCTAssertNil(Client.errorMessage(from: Data()))
    }

    func testMakeRequestTargetsChatCompletionsWithStreamingBody() throws {
        let configuration = try XCTUnwrap(QuickAIConfiguration(
            baseURLString: "https://api.openai.com/v1",
            model: "gpt-4o-mini",
            apiKey: "sk-test"
        ))

        let request = OpenAICompatibleQuickAIClient.makeRequest(question: "1+1?", configuration: configuration)

        XCTAssertEqual(request.url?.absoluteString, "https://api.openai.com/v1/chat/completions")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-test")
        let body = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["model"] as? String, "gpt-4o-mini")
        XCTAssertEqual(json["stream"] as? Bool, true)
        let messages = try XCTUnwrap(json["messages"] as? [[String: String]])
        XCTAssertEqual(messages.last, ["role": "user", "content": "1+1?"])
    }

    func testMakeRequestKeepsFullEndpointAndOmitsMissingKey() throws {
        let configuration = try XCTUnwrap(QuickAIConfiguration(
            baseURLString: "http://localhost:11434/v1/chat/completions",
            model: "qwen2.5",
            apiKey: nil
        ))

        let request = OpenAICompatibleQuickAIClient.makeRequest(question: "hi", configuration: configuration)

        XCTAssertEqual(request.url?.absoluteString, "http://localhost:11434/v1/chat/completions")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
    }

    func testMakeRequestNormalizesTrailingSlashOnEndpoint() throws {
        let configuration = try XCTUnwrap(QuickAIConfiguration(
            baseURLString: "https://api.openai.com/v1/chat/completions/",
            model: "gpt-4o-mini",
            apiKey: nil
        ))

        let request = OpenAICompatibleQuickAIClient.makeRequest(question: "hi", configuration: configuration)
        XCTAssertEqual(request.url?.absoluteString, "https://api.openai.com/v1/chat/completions")
    }

    // MARK: - Markdown

    func testMarkdownSplitsBlockElements() {
        let markdown = """
        # 标题
        第一行
        第二行

        - 苹果
          - 青苹果
        2. 第二步
        > 引用一
        > 引用二
        ---
        ```swift
        let a = 1
        ```
        """

        XCTAssertEqual(QuickAIMarkdown.blocks(from: markdown), [
            .heading(level: 1, text: "标题"),
            .paragraph("第一行\n第二行"),
            .listItem(marker: "•", text: "苹果", indent: 0),
            .listItem(marker: "•", text: "青苹果", indent: 1),
            .listItem(marker: "2.", text: "第二步", indent: 0),
            .quote("引用一\n引用二"),
            .rule,
            .code(language: "swift", code: "let a = 1"),
        ])
    }

    func testMarkdownRendersUnclosedCodeFenceWhileStreaming() {
        XCTAssertEqual(
            QuickAIMarkdown.blocks(from: "示例：\n```\nprint(1)"),
            [.paragraph("示例："), .code(language: "", code: "print(1)")]
        )
    }

    func testMarkdownDoesNotTreatHashtagOrDecimalAsBlock() {
        XCTAssertEqual(
            QuickAIMarkdown.blocks(from: "#tag\n3.14 是圆周率"),
            [.paragraph("#tag\n3.14 是圆周率")]
        )
    }

    func testMarkdownHandlesCRLFNewlines() {
        let markdown = "# 标题\r\n第一段\r\n\r\n第二段"
        XCTAssertEqual(QuickAIMarkdown.blocks(from: markdown), [
            .heading(level: 1, text: "标题"),
            .paragraph("第一段"),
            .paragraph("第二段"),
        ])
    }

    func testMarkdownParsesTableAndPadsShortRows() {
        let markdown = """
        | 名称 | 价格 |
        | :--- | ---: |
        | 苹果 | 3 |
        | 香蕉 |
        后记
        """
        XCTAssertEqual(QuickAIMarkdown.blocks(from: markdown), [
            .table(header: ["名称", "价格"], rows: [["苹果", "3"], ["香蕉", ""]]),
            .paragraph("后记"),
        ])
    }

    func testMarkdownShowsTableHeaderAsParagraphUntilSeparatorArrives() {
        XCTAssertEqual(
            QuickAIMarkdown.blocks(from: "| 名称 | 价格 |"),
            [.paragraph("| 名称 | 价格 |")]
        )
    }

    func testMarkdownSupportsTildeFenceAndOnlyMatchingFenceCloses() {
        let markdown = "~~~python\n```\nprint(1)\n~~~"
        XCTAssertEqual(QuickAIMarkdown.blocks(from: markdown), [
            .code(language: "python", code: "```\nprint(1)"),
        ])
    }

    func testRemovingThinkingHidesClosedAndUnclosedReasoning() {
        XCTAssertEqual(
            QuickAIMarkdown.removingThinking(from: "<think>\n先想想\n</think>\n\n答案是 2"),
            "答案是 2"
        )
        XCTAssertEqual(QuickAIMarkdown.removingThinking(from: "<think>\n还在想"), "")
        XCTAssertEqual(QuickAIMarkdown.removingThinking(from: "没有思考"), "没有思考")
    }

    // MARK: - Use case

    func testAskQuickAIThrowsNotConfiguredWithoutRequesting() async {
        let answerer = StubQuickAIAnswerer(deltas: ["不应到达"])
        let useCase = AskQuickAI(
            answerer: answerer,
            settingsStore: MemoryAppSettingsStore(),
            keyStore: MemoryQuickAIKeyStore()
        )

        do {
            try await useCase.execute(question: "hi") { _ in XCTFail("不应收到增量") }
            XCTFail("应抛出未配置错误")
        } catch {
            XCTAssertEqual(error as? ApplicationError, .quickAINotConfigured)
        }
    }

    func testAskQuickAIPassesKeyAndMapsFailures() async {
        let answerer = StubQuickAIAnswerer(deltas: ["半"], error: QuickAIClientError.httpStatus(401, "Incorrect API key"))
        let useCase = AskQuickAI(
            answerer: answerer,
            settingsStore: configuredSettingsStore(),
            keyStore: MemoryQuickAIKeyStore(initial: "sk-test")
        )
        var received: [String] = []

        do {
            try await useCase.execute(question: "hi") { received.append($0) }
            XCTFail("应抛出失败错误")
        } catch {
            XCTAssertEqual(error as? ApplicationError, .quickAIFailed(reason: "服务返回 401：Incorrect API key"))
        }
        XCTAssertEqual(received, ["半"])
        XCTAssertEqual(answerer.recorder.configurations.first?.apiKey, "sk-test")
    }

    // MARK: - View model

    func testTabEntersQuickAIModeBeforeTypingQuestion() {
        let viewModel = makeQuickAIViewModel(answerer: StubQuickAIAnswerer(deltas: []))

        viewModel.toggleQuickAIMode()
        viewModel.query = "1+1 等于几"

        XCTAssertTrue(viewModel.isQuickAIModeActive)
        XCTAssertNil(viewModel.quickAISession)
        XCTAssertFalse(viewModel.isExpanded)
        XCTAssertNil(viewModel.selectedResult)
        XCTAssertEqual(viewModel.panelHeight, LauncherLayout.searchHeight)
    }

    func testTabTogglesBackToSearchKeepingText() async throws {
        let viewModel = makeQuickAIViewModel(answerer: StubQuickAIAnswerer(deltas: ["回答"]))
        viewModel.toggleQuickAIMode()
        viewModel.query = "问题"
        try await XCTUnwrap(viewModel.startQuickAI()).value

        viewModel.toggleQuickAIMode()

        XCTAssertFalse(viewModel.isQuickAIModeActive)
        XCTAssertNil(viewModel.quickAISession)
        XCTAssertEqual(viewModel.query, "问题")
        XCTAssertTrue(viewModel.isExpanded)
        XCTAssertNotEqual(viewModel.expandedContent, .quickAI)
    }

    func testQuickAIRequiresQuickAIMode() {
        let viewModel = makeQuickAIViewModel(answerer: StubQuickAIAnswerer(deltas: []))
        viewModel.query = "问题"

        XCTAssertNil(viewModel.startQuickAI())
        XCTAssertNil(viewModel.quickAISession)
    }

    func testEnterStartsQuickAIAndStreamsAnswer() async throws {
        let viewModel = makeQuickAIViewModel(answerer: StubQuickAIAnswerer(deltas: ["**1+1**", " = 2"]))
        viewModel.toggleQuickAIMode()
        viewModel.query = "1+1 等于几"

        let task = try XCTUnwrap(viewModel.startQuickAI())
        XCTAssertEqual(viewModel.quickAISession?.question, "1+1 等于几")
        XCTAssertEqual(viewModel.expandedContent, .quickAI)
        XCTAssertEqual(
            viewModel.panelHeight,
            LauncherLayout.totalHeight(isExpanded: true, content: .quickAI)
        )
        XCTAssertNil(viewModel.selectedResult)

        await task.value

        XCTAssertEqual(viewModel.quickAISession?.answer, "**1+1** = 2")
        XCTAssertEqual(viewModel.quickAISession?.state, .finished)
        XCTAssertEqual(viewModel.quickAIAnswerToCopy, "**1+1** = 2")
    }

    func testQuickAIIgnoresEmptyQuery() {
        let viewModel = makeQuickAIViewModel(answerer: StubQuickAIAnswerer(deltas: []))
        viewModel.toggleQuickAIMode()
        viewModel.query = "   "

        XCTAssertNil(viewModel.startQuickAI())
        XCTAssertNil(viewModel.quickAISession)
    }

    func testQuickAIShowsConfigurationHintWhenNotConfigured() async throws {
        let viewModel = makeQuickAIViewModel(
            answerer: StubQuickAIAnswerer(deltas: []),
            settingsStore: MemoryAppSettingsStore()
        )
        viewModel.toggleQuickAIMode()
        viewModel.query = "hi"

        try await XCTUnwrap(viewModel.startQuickAI()).value

        guard case .failed(let message)? = viewModel.quickAISession?.state else {
            return XCTFail("应展示未配置提示")
        }
        XCTAssertTrue(message.contains("Quick AI"))
        XCTAssertNil(viewModel.quickAIAnswerToCopy)
    }

    func testStopQuickAIKeepsPartialAnswer() async throws {
        let viewModel = makeQuickAIViewModel(answerer: HangingQuickAIAnswerer())
        viewModel.toggleQuickAIMode()
        viewModel.query = "写一首诗"
        let task = try XCTUnwrap(viewModel.startQuickAI())
        try await waitUntil { viewModel.quickAISession?.answer.isEmpty == false }

        viewModel.stopQuickAI()
        await task.value

        XCTAssertEqual(viewModel.quickAISession?.answer, "床前")
        XCTAssertEqual(viewModel.quickAISession?.state, .finished)
    }

    func testEditingQuestionDiscardsAnswerButStaysInQuickAIMode() async throws {
        let viewModel = makeQuickAIViewModel(answerer: HangingQuickAIAnswerer())
        viewModel.toggleQuickAIMode()
        viewModel.query = "写一首诗"
        let task = try XCTUnwrap(viewModel.startQuickAI())
        try await waitUntil { viewModel.quickAISession?.answer.isEmpty == false }

        viewModel.query = "写一首词"
        await task.value

        XCTAssertNil(viewModel.quickAISession)
        XCTAssertTrue(viewModel.isQuickAIModeActive)
        XCTAssertFalse(viewModel.isExpanded)
    }

    func testAnswerToCopyExcludesThinking() async throws {
        let viewModel = makeQuickAIViewModel(
            answerer: StubQuickAIAnswerer(deltas: ["<think>推理", "</think>", "答案"])
        )
        viewModel.toggleQuickAIMode()
        viewModel.query = "问题"
        try await XCTUnwrap(viewModel.startQuickAI()).value

        XCTAssertEqual(viewModel.quickAISession?.answer, "<think>推理</think>答案")
        XCTAssertEqual(viewModel.quickAIAnswerToCopy, "答案")
    }

    func testScrollQuickAIAnswerOnlyWithSession() async throws {
        let viewModel = makeQuickAIViewModel(answerer: StubQuickAIAnswerer(deltas: ["回答"]))
        viewModel.toggleQuickAIMode()
        viewModel.scrollQuickAIAnswer(by: 1)
        XCTAssertEqual(viewModel.quickAIScrollRequest, QuickAIScrollRequest())

        viewModel.query = "问题"
        try await XCTUnwrap(viewModel.startQuickAI()).value
        viewModel.scrollQuickAIAnswer(by: 1)
        viewModel.scrollQuickAIAnswer(by: 1)

        XCTAssertEqual(viewModel.quickAIScrollRequest, QuickAIScrollRequest(direction: 1, serial: 2))
    }

    func testReturnActionFollowsSessionState() {
        var session = QuickAISession(question: "问题")
        XCTAssertEqual(session.returnAction, .none)

        session.state = .finished
        XCTAssertEqual(session.returnAction, .retry, "空回答应提示重试")

        session.answer = "<think>推理</think>"
        XCTAssertEqual(session.returnAction, .retry, "只有思考内容视为空回答")

        session.answer = "答案"
        XCTAssertEqual(session.returnAction, .copyAndClose)

        session.state = .failed("超时")
        XCTAssertEqual(session.returnAction, .retry, "输出到一半失败也应重试")
    }

    func testRetryAfterFailureStartsNewSession() async throws {
        let viewModel = makeQuickAIViewModel(
            answerer: StubQuickAIAnswerer(deltas: []),
            settingsStore: MemoryAppSettingsStore()
        )
        viewModel.toggleQuickAIMode()
        viewModel.query = "问题"
        try await XCTUnwrap(viewModel.startQuickAI()).value
        XCTAssertEqual(viewModel.quickAISession?.returnAction, .retry)

        let retry = try XCTUnwrap(viewModel.startQuickAI())
        XCTAssertEqual(viewModel.quickAISession?.state, .streaming)
        await retry.value
    }

    func testMarkQuickAIAnswerCopied() async throws {
        let viewModel = makeQuickAIViewModel(answerer: StubQuickAIAnswerer(deltas: ["答案"]))
        viewModel.toggleQuickAIMode()
        viewModel.query = "问题"
        try await XCTUnwrap(viewModel.startQuickAI()).value

        viewModel.markQuickAIAnswerCopied()

        XCTAssertEqual(viewModel.quickAISession?.isAnswerCopied, true)
    }

    func testPrepareForPresentationResetsQuickAISession() async throws {
        let viewModel = makeQuickAIViewModel(answerer: StubQuickAIAnswerer(deltas: ["回答"]))
        viewModel.toggleQuickAIMode()
        viewModel.query = "问题"
        try await XCTUnwrap(viewModel.startQuickAI()).value
        XCTAssertNotNil(viewModel.quickAISession)
        XCTAssertTrue(viewModel.isExpanded)

        viewModel.prepareForPresentation()

        XCTAssertNil(viewModel.quickAISession)
        XCTAssertFalse(viewModel.isQuickAIModeActive)
        XCTAssertEqual(viewModel.query, "")
        XCTAssertFalse(viewModel.isExpanded)
    }

    // MARK: - Settings

    func testUserDefaultsStoreRoundTripsQuickAISettings() throws {
        let suiteName = "OITests-QuickAI-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = AppSettings(quickAIBaseURL: "http://localhost:11434/v1", quickAIModel: "qwen2.5")

        UserDefaultsAppSettingsStore(defaults: defaults).save(settings)

        XCTAssertEqual(UserDefaultsAppSettingsStore(defaults: defaults).load(), settings)
    }

    func testSettingsViewModelSavesAndReloadsAPIKey() {
        let keyStore = MemoryQuickAIKeyStore(initial: "sk-old")
        let viewModel = SettingsViewModel(
            settingsStore: MemoryAppSettingsStore(),
            loginItemController: StubLoginItemController(),
            quickAIKeyStore: keyStore
        )
        XCTAssertEqual(viewModel.quickAIAPIKey, "")

        viewModel.reloadQuickAIAPIKey()
        XCTAssertEqual(viewModel.quickAIAPIKey, "sk-old")

        viewModel.setQuickAIAPIKey(" sk-new ")
        XCTAssertEqual(keyStore.load(), "sk-old", "输入过程中不应写入")
        viewModel.commitQuickAIAPIKey()
        XCTAssertEqual(keyStore.load(), "sk-new")

        viewModel.setQuickAIAPIKey("")
        viewModel.commitQuickAIAPIKey()
        XCTAssertNil(keyStore.load())
    }

    func testKeychainQuickAIKeyStoreRoundTripsAndDeletes() {
        let testService = "OITests.KeychainQuickAIKeyStore.\(UUID().uuidString)"
        let store = KeychainQuickAIKeyStore(service: testService)
        defer { store.save(nil) }

        XCTAssertNil(store.load())

        store.save("sk-keychain-test")
        XCTAssertEqual(store.load(), "sk-keychain-test")

        store.save("sk-keychain-updated")
        XCTAssertEqual(store.load(), "sk-keychain-updated")

        store.save("  ")
        XCTAssertNil(store.load())
    }

    // MARK: - Helpers

    private func configuredSettingsStore() -> MemoryAppSettingsStore {
        MemoryAppSettingsStore(initial: AppSettings(
            quickAIBaseURL: "https://api.openai.com/v1",
            quickAIModel: "gpt-4o-mini"
        ))
    }

    private func makeQuickAIViewModel(
        answerer: any QuickAIAnswering,
        settingsStore: MemoryAppSettingsStore? = nil
    ) -> LauncherViewModel {
        let settingsStore = settingsStore ?? configuredSettingsStore()
        return LauncherViewModel(
            discoverApplications: DiscoverApplications(catalog: StubAppCatalog(descriptors: [])),
            launchApplication: LaunchApplication(launcher: StubApplicationLauncher()),
            askQuickAI: AskQuickAI(
                answerer: answerer,
                settingsStore: settingsStore,
                keyStore: MemoryQuickAIKeyStore()
            ),
            settingsStore: settingsStore
        )
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        var attempts = 0
        while !condition(), attempts < 1000 {
            attempts += 1
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertTrue(condition())
    }
}

/// Records the configurations the answerer was asked with.
private final class QuickAIRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedConfigurations: [QuickAIConfiguration] = []

    var configurations: [QuickAIConfiguration] {
        lock.withLock { storedConfigurations }
    }

    func record(_ configuration: QuickAIConfiguration) {
        lock.withLock { storedConfigurations.append(configuration) }
    }
}

/// Yields the given deltas, then finishes (or fails with `error`).
private struct StubQuickAIAnswerer: QuickAIAnswering {
    let deltas: [String]
    let error: QuickAIClientError?
    let recorder = QuickAIRequestRecorder()

    init(deltas: [String], error: QuickAIClientError? = nil) {
        self.deltas = deltas
        self.error = error
    }

    func streamAnswer(
        to question: String,
        configuration: QuickAIConfiguration
    ) -> AsyncThrowingStream<String, Error> {
        recorder.record(configuration)
        return AsyncThrowingStream { continuation in
            for delta in deltas {
                continuation.yield(delta)
            }
            continuation.finish(throwing: error)
        }
    }
}

/// Yields one delta and never finishes: an answer still being generated.
/// Continuations are retained so the stream only ends when the consumer cancels.
private final class HangingQuickAIAnswerer: QuickAIAnswering, @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [AsyncThrowingStream<String, Error>.Continuation] = []

    func streamAnswer(
        to question: String,
        configuration: QuickAIConfiguration
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            lock.withLock { continuations.append(continuation) }
            continuation.yield("床前")
        }
    }
}

@MainActor
private final class StubLoginItemController: LoginItemControlling {
    var status: LoginItemStatus = .notRegistered

    func register() throws {}
    func unregister() throws {}
}
