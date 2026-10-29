import Foundation
import Security
import XCTest

@testable import OI

@MainActor
final class QuickAITests: XCTestCase {
    // MARK: - 接口配置

    func testConfigurationRequiresHTTPURLAndModel() {
        XCTAssertNil(AIEndpointConfiguration(baseURLString: "", model: "gpt", apiKey: nil))
        XCTAssertNil(AIEndpointConfiguration(baseURLString: "ftp://example.com", model: "gpt", apiKey: nil))
        XCTAssertNil(AIEndpointConfiguration(baseURLString: "https://api.openai.com/v1", model: "  ", apiKey: nil))

        let configuration = AIEndpointConfiguration(
            baseURLString: " http://localhost:11434/v1 ",
            model: " qwen2.5 ",
            apiKey: "  "
        )
        XCTAssertEqual(configuration?.baseURL.absoluteString, "http://localhost:11434/v1")
        XCTAssertEqual(configuration?.model, "qwen2.5")
        XCTAssertNil(configuration?.apiKey)
    }

    func testConfigurationTrimsReasoningEffort() {
        func reasoningEffort(_ string: String?) -> String? {
            let configuration = AIEndpointConfiguration(
                baseURLString: "https://api.openai.com/v1",
                model: "gpt",
                apiKey: nil,
                reasoningEffort: string
            )
            return configuration?.reasoningEffort
        }
        XCTAssertEqual(reasoningEffort(" low "), "low")
        XCTAssertNil(reasoningEffort("  "))
        XCTAssertNil(reasoningEffort(nil))
    }

    func testConfigurationAddsMissingScheme() {
        func baseURL(_ string: String) -> String? {
            AIEndpointConfiguration(baseURLString: string, model: "gpt", apiKey: nil)?.baseURL.absoluteString
        }
        XCTAssertEqual(baseURL("api.openai.com/v1"), "https://api.openai.com/v1")
        XCTAssertEqual(baseURL(" localhost:11434/v1 "), "http://localhost:11434/v1")
        XCTAssertEqual(baseURL("127.0.0.1:11434/v1"), "http://127.0.0.1:11434/v1")
        XCTAssertEqual(baseURL("192.168.1.8:11434/v1"), "http://192.168.1.8:11434/v1")
        XCTAssertEqual(baseURL("HTTPS://api.openai.com/v1"), "HTTPS://api.openai.com/v1")
        XCTAssertEqual(baseURL("172.20.10.2:11434/v1"), "http://172.20.10.2:11434/v1")
        XCTAssertEqual(baseURL("172.32.0.1/v1"), "https://172.32.0.1/v1")
        XCTAssertEqual(baseURL("[::1]:11434/v1"), "http://[::1]:11434/v1")
        // 以数字开头的域名不是局域网地址。
        XCTAssertEqual(baseURL("10.example.com/v1"), "https://10.example.com/v1")
    }

    func testPlaintextOverPublicNetworkOnlyForHTTPToNonLocalHosts() {
        func isPlaintext(_ string: String) -> Bool {
            AIEndpointConfiguration.isPlaintextOverPublicNetwork(baseURLString: string)
        }
        XCTAssertTrue(isPlaintext("http://203.0.113.10:11434/v1"))
        XCTAssertTrue(isPlaintext(" HTTP://api.example.com/v1 "))
        XCTAssertFalse(isPlaintext("https://203.0.113.10/v1"))
        XCTAssertFalse(isPlaintext("api.example.com/v1"))
        XCTAssertFalse(isPlaintext("http://localhost:11434/v1"))
        XCTAssertFalse(isPlaintext("http://127.0.0.1:11434/v1"))
        XCTAssertFalse(isPlaintext("http://192.168.1.8:11434/v1"))
        XCTAssertFalse(isPlaintext("http://mac-mini.local:11434/v1"))
        XCTAssertFalse(isPlaintext("http://172.20.10.2:11434/v1"))
        XCTAssertFalse(isPlaintext("http://169.254.10.20:11434/v1"))
        XCTAssertFalse(isPlaintext("http://[::1]:11434/v1"))
        XCTAssertFalse(isPlaintext("http://[fd12:3456::5]:11434/v1"))
        XCTAssertTrue(isPlaintext("http://172.32.0.1/v1"))
        XCTAssertFalse(isPlaintext(""))
    }

    // MARK: - OpenAI 兼容客户端

    func testParseStreamLineExtractsDeltaDoneAndErrors() {
        typealias Client = OpenAICompatibleAIClient
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
        typealias Client = OpenAICompatibleAIClient
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
        let configuration = try XCTUnwrap(AIEndpointConfiguration(
            baseURLString: "https://api.openai.com/v1",
            model: "gpt-4o-mini",
            apiKey: "sk-test"
        ))

        let request = OpenAICompatibleAIClient.makeRequest(
            question: "1+1?",
            systemPrompt: AskQuickAI.systemPrompt,
            configuration: configuration
        )

        XCTAssertEqual(request.url?.absoluteString, "https://api.openai.com/v1/chat/completions")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.timeoutInterval, OpenAICompatibleAIClient.idleTimeout)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-test")
        let body = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["model"] as? String, "gpt-4o-mini")
        XCTAssertEqual(json["stream"] as? Bool, true)
        let messages = try XCTUnwrap(json["messages"] as? [[String: String]])
        XCTAssertEqual(messages.first, ["role": "system", "content": AskQuickAI.systemPrompt])
        XCTAssertEqual(messages.last, ["role": "user", "content": "1+1?"])
    }

    func testMakeRequestKeepsFullEndpointAndOmitsMissingKey() throws {
        let configuration = try XCTUnwrap(AIEndpointConfiguration(
            baseURLString: "http://localhost:11434/v1/chat/completions",
            model: "qwen2.5",
            apiKey: nil
        ))

        let request = OpenAICompatibleAIClient.makeRequest(
            question: "hi",
            systemPrompt: AskQuickAI.systemPrompt,
            configuration: configuration
        )

        XCTAssertEqual(request.url?.absoluteString, "http://localhost:11434/v1/chat/completions")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
    }

    /// 未填写思考强度时请求中不带 `reasoning_effort` 字段：不支持该参数的服务可能直接拒绝请求。
    func testMakeRequestSendsReasoningEffortOnlyWhenSet() throws {
        func body(reasoningEffort: String?) throws -> [String: Any] {
            let configuration = try XCTUnwrap(AIEndpointConfiguration(
                baseURLString: "https://api.openai.com/v1",
                model: "gpt-5-mini",
                apiKey: nil,
                reasoningEffort: reasoningEffort
            ))
            let request = OpenAICompatibleAIClient.makeRequest(
                question: "hi",
                systemPrompt: AskQuickAI.systemPrompt,
                configuration: configuration
            )
            return try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        }

        XCTAssertEqual(try body(reasoningEffort: "low")["reasoning_effort"] as? String, "low")
        XCTAssertNil(try body(reasoningEffort: nil)["reasoning_effort"])
    }

    func testMakeRequestNormalizesTrailingSlashOnEndpoint() throws {
        let configuration = try XCTUnwrap(AIEndpointConfiguration(
            baseURLString: "https://api.openai.com/v1/chat/completions/",
            model: "gpt-4o-mini",
            apiKey: nil
        ))

        let request = OpenAICompatibleAIClient.makeRequest(
            question: "hi",
            systemPrompt: AskQuickAI.systemPrompt,
            configuration: configuration
        )
        XCTAssertEqual(request.url?.absoluteString, "https://api.openai.com/v1/chat/completions")
    }

    /// 追问时此前各轮的问答依次排在系统指令之后、本次提问之前。
    func testMakeRequestPlacesHistoryBetweenSystemPromptAndQuestion() throws {
        let configuration = try XCTUnwrap(AIEndpointConfiguration(
            baseURLString: "https://api.openai.com/v1",
            model: "gpt-4o-mini",
            apiKey: nil
        ))

        let request = OpenAICompatibleAIClient.makeRequest(
            question: "第二问",
            history: [AIConversationTurn(question: "第一问", answer: "答一")],
            systemPrompt: AskQuickAI.systemPrompt,
            configuration: configuration
        )

        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual(json["messages"] as? [[String: String]], [
            ["role": "system", "content": AskQuickAI.systemPrompt],
            ["role": "user", "content": "第一问"],
            ["role": "assistant", "content": "答一"],
            ["role": "user", "content": "第二问"],
        ])
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

        XCTAssertEqual(MarkdownParser.blocks(from: markdown), [
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

    func testMarkdownTrimsExtraSpacesAfterBullet() {
        XCTAssertEqual(
            MarkdownParser.blocks(from: "-   苹果\n*  香蕉"),
            [
                .listItem(marker: "•", text: "苹果", indent: 0),
                .listItem(marker: "•", text: "香蕉", indent: 0),
            ]
        )
    }

    func testMarkdownRendersUnclosedCodeFenceWhileStreaming() {
        XCTAssertEqual(
            MarkdownParser.blocks(from: "示例：\n```\nprint(1)"),
            [.paragraph("示例："), .code(language: "", code: "print(1)")]
        )
    }

    func testMarkdownDoesNotTreatHashtagOrDecimalAsBlock() {
        XCTAssertEqual(
            MarkdownParser.blocks(from: "#tag\n3.14 是圆周率"),
            [.paragraph("#tag\n3.14 是圆周率")]
        )
    }

    func testMarkdownHandlesCRLFNewlines() {
        let markdown = "# 标题\r\n第一段\r\n\r\n第二段"
        XCTAssertEqual(MarkdownParser.blocks(from: markdown), [
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
        XCTAssertEqual(MarkdownParser.blocks(from: markdown), [
            .table(header: ["名称", "价格"], rows: [["苹果", "3"], ["香蕉", ""]]),
            .paragraph("后记"),
        ])
    }

    func testMarkdownShowsTableHeaderAsParagraphUntilSeparatorArrives() {
        XCTAssertEqual(
            MarkdownParser.blocks(from: "| 名称 | 价格 |"),
            [.paragraph("| 名称 | 价格 |")]
        )
    }

    func testMarkdownSupportsTildeFenceAndOnlyMatchingFenceCloses() {
        let markdown = "~~~python\n```\nprint(1)\n~~~"
        XCTAssertEqual(MarkdownParser.blocks(from: markdown), [
            .code(language: "python", code: "```\nprint(1)"),
        ])
    }

    func testRemovingThinkingHidesClosedAndUnclosedReasoning() {
        XCTAssertEqual(
            MarkdownParser.removingThinking(from: "<think>\n先想想\n</think>\n\n答案是 2"),
            "答案是 2"
        )
        XCTAssertEqual(MarkdownParser.removingThinking(from: "<think>\n还在想"), "")
        XCTAssertEqual(MarkdownParser.removingThinking(from: "没有思考"), "没有思考")
        XCTAssertEqual(
            MarkdownParser.removingThinking(from: "<think> 标签用于包裹推理过程。"),
            "",
            "以 <think> 开头且未闭合时按推理中处理"
        )
        XCTAssertEqual(
            MarkdownParser.removingThinking(from: "DeepSeek 用 <think> 标签包裹推理过程。"),
            "DeepSeek 用 <think> 标签包裹推理过程。",
            "正文中提到的 <think> 不应被截断"
        )
    }

    // MARK: - 用例

    func testAskQuickAIThrowsNotConfiguredWithoutRequesting() async {
        let answerer = StubAIAnswerer(deltas: ["不应到达"])
        let useCase = AskQuickAI(
            answerer: answerer,
            settingsStore: MemoryAppSettingsStore(),
            keyStore: MemoryAPIKeyStore()
        )

        do {
            try await useCase.execute(question: "hi", history: []) { _ in XCTFail("不应收到增量") }
            XCTFail("应抛出未配置错误")
        } catch {
            XCTAssertEqual(error as? ApplicationError, .aiNotConfigured)
        }
    }

    func testAskQuickAIPassesKeyAndMapsFailures() async {
        let answerer = StubAIAnswerer(deltas: ["半"], error: AIClientError.httpStatus(401, "Incorrect API key"))
        let useCase = AskQuickAI(
            answerer: answerer,
            settingsStore: configuredSettingsStore(),
            keyStore: MemoryAPIKeyStore(initial: "sk-test")
        )
        var received: [String] = []

        do {
            try await useCase.execute(question: "hi", history: []) { received.append($0) }
            XCTFail("应抛出失败错误")
        } catch {
            XCTAssertEqual(error as? ApplicationError, .aiRequestFailed(reason: "服务返回 401：Incorrect API key"))
        }
        XCTAssertEqual(received, ["半"])
        XCTAssertEqual(answerer.recorder.configurations.first?.apiKey, "sk-test")
    }

    func testAskQuickAIUsesQuickAIReasoningEffort() async throws {
        let answerer = StubAIAnswerer(deltas: ["2"])
        let useCase = AskQuickAI(
            answerer: answerer,
            settingsStore: MemoryAppSettingsStore(initial: AppSettings(
                quickAIBaseURL: "https://api.openai.com/v1",
                quickAIModel: "gpt-5-mini",
                quickAIReasoningEffort: "high",
                translationReasoningEffort: "low"
            )),
            keyStore: MemoryAPIKeyStore()
        )

        try await useCase.execute(question: "1+1", history: []) { _ in }

        XCTAssertEqual(answerer.recorder.configurations.first?.reasoningEffort, "high")
    }

    // MARK: - 视图模型

    func testTabEntersQuickAIModeBeforeTypingQuestion() {
        let viewModel = makeQuickAIViewModel(answerer: StubAIAnswerer(deltas: []))

        viewModel.toggleQuickAIMode()
        viewModel.query = "1+1 等于几"

        XCTAssertTrue(viewModel.isQuickAIModeActive)
        XCTAssertNil(viewModel.quickAISession)
        XCTAssertFalse(viewModel.isExpanded)
        XCTAssertNil(viewModel.selectedResult)
        XCTAssertEqual(viewModel.panelHeight, LauncherLayout.searchHeight)
    }

    /// `Tab` 返回检索即结束这段对话，输入框中的草稿成为检索词；再按 `Tab` 是新的对话。
    func testTabTogglesBackToSearchKeepingDraftAndEndsConversation() async throws {
        let viewModel = makeQuickAIViewModel(answerer: StubAIAnswerer(deltas: ["回答"]))
        viewModel.toggleQuickAIMode()
        viewModel.query = "问题"
        try await XCTUnwrap(viewModel.startQuickAI()).value
        viewModel.query = "草稿"

        viewModel.toggleQuickAIMode()

        XCTAssertFalse(viewModel.isQuickAIModeActive)
        XCTAssertNil(viewModel.quickAISession)
        XCTAssertEqual(viewModel.query, "草稿")
        XCTAssertTrue(viewModel.isExpanded)
        XCTAssertNotEqual(viewModel.expandedContent, .quickAI)

        viewModel.toggleQuickAIMode()

        XCTAssertTrue(viewModel.isQuickAIModeActive)
        XCTAssertNil(viewModel.quickAISession)
    }

    func testQuickAIRequiresQuickAIMode() {
        let viewModel = makeQuickAIViewModel(answerer: StubAIAnswerer(deltas: []))
        viewModel.query = "问题"

        XCTAssertNil(viewModel.startQuickAI())
        XCTAssertNil(viewModel.quickAISession)
    }

    func testEnterStartsQuickAIAndStreamsAnswer() async throws {
        let viewModel = makeQuickAIViewModel(answerer: StubAIAnswerer(deltas: ["**1+1**", " = 2"]))
        viewModel.toggleQuickAIMode()
        viewModel.query = "1+1 等于几"

        let task = try XCTUnwrap(viewModel.startQuickAI())
        XCTAssertEqual(viewModel.quickAISession?.turns.map(\.question), ["1+1 等于几"])
        XCTAssertEqual(viewModel.query, "", "问题移到回答区，输入框清空")
        XCTAssertEqual(viewModel.expandedContent, .quickAI)
        XCTAssertEqual(
            viewModel.panelHeight,
            LauncherLayout.totalHeight(isExpanded: true, content: .quickAI)
        )
        XCTAssertNil(viewModel.selectedResult)

        await task.value

        XCTAssertEqual(viewModel.quickAISession?.lastTurn.answer, "**1+1** = 2")
        XCTAssertEqual(viewModel.quickAISession?.lastTurn.state, .finished)
        XCTAssertEqual(viewModel.quickAIAnswerToCopy, "**1+1** = 2")
        XCTAssertEqual(viewModel.quickAIReturnAction, .copyAndClose)
    }

    func testFollowUpAppendsTurnAndSendsEarlierTurns() async throws {
        let answerer = StubAIAnswerer(deltas: ["<think>推理</think>", "回答"])
        let viewModel = makeQuickAIViewModel(answerer: answerer)
        viewModel.toggleQuickAIMode()
        viewModel.query = "第一问"
        try await XCTUnwrap(viewModel.startQuickAI()).value
        viewModel.markQuickAIAnswerCopied()

        viewModel.query = "第二问"
        XCTAssertEqual(viewModel.quickAIReturnAction, .followUp)
        let followUp = try XCTUnwrap(viewModel.startQuickAI())
        XCTAssertEqual(viewModel.query, "")
        XCTAssertEqual(viewModel.quickAISession?.isAnswerCopied, false)
        XCTAssertEqual(viewModel.quickAISession?.turns.first?.answer, "<think>推理</think>回答", "追问不清空已有回答")
        await followUp.value

        XCTAssertEqual(viewModel.quickAISession?.turns.map(\.question), ["第一问", "第二问"])
        XCTAssertEqual(viewModel.quickAISession?.lastTurn.state, .finished)
        XCTAssertEqual(answerer.recorder.questions, ["第一问", "第二问"])
        XCTAssertEqual(
            answerer.recorder.histories,
            [[], [AIConversationTurn(question: "第一问", answer: "回答")]],
            "历史中的回答不含推理内容"
        )
    }

    func testQuickAIIgnoresEmptyQuery() {
        let viewModel = makeQuickAIViewModel(answerer: StubAIAnswerer(deltas: []))
        viewModel.toggleQuickAIMode()
        viewModel.query = "   "

        XCTAssertNil(viewModel.startQuickAI())
        XCTAssertNil(viewModel.quickAISession)
    }

    func testQuickAIShowsConfigurationHintWhenNotConfigured() async throws {
        let viewModel = makeQuickAIViewModel(
            answerer: StubAIAnswerer(deltas: []),
            settingsStore: MemoryAppSettingsStore()
        )
        viewModel.toggleQuickAIMode()
        viewModel.query = "hi"

        try await XCTUnwrap(viewModel.startQuickAI()).value

        guard case .failed(let message)? = viewModel.quickAISession?.lastTurn.state else {
            return XCTFail("应展示未配置提示")
        }
        XCTAssertTrue(message.contains("Quick AI"))
        XCTAssertNil(viewModel.quickAIAnswerToCopy)
    }

    func testStopQuickAIKeepsPartialAnswer() async throws {
        let viewModel = makeQuickAIViewModel(answerer: HangingAIAnswerer())
        viewModel.toggleQuickAIMode()
        viewModel.query = "写一首诗"
        let task = try XCTUnwrap(viewModel.startQuickAI())
        try await waitUntil { viewModel.quickAISession?.lastTurn.answer.isEmpty == false }

        viewModel.stopQuickAI()
        await task.value

        XCTAssertEqual(viewModel.quickAISession?.lastTurn.answer, "床前")
        XCTAssertEqual(viewModel.quickAISession?.lastTurn.state, .finished)
    }

    /// 输出期间可以写下一条消息的草稿：不清空回答、不中断输出，发送与重试都不响应。
    func testDraftWhileStreamingKeepsAnswerAndCannotSend() async throws {
        let viewModel = makeQuickAIViewModel(answerer: HangingAIAnswerer())
        viewModel.toggleQuickAIMode()
        viewModel.query = "写一首诗"
        let task = try XCTUnwrap(viewModel.startQuickAI())
        try await waitUntil { viewModel.quickAISession?.lastTurn.answer.isEmpty == false }

        viewModel.query = "再写一首"

        XCTAssertEqual(viewModel.quickAIReturnAction, QuickAISession.ReturnAction.none)
        XCTAssertNil(viewModel.startQuickAI())
        XCTAssertNil(viewModel.retryQuickAI())
        XCTAssertEqual(viewModel.query, "再写一首")
        XCTAssertEqual(viewModel.quickAISession?.turns.count, 1)
        XCTAssertEqual(viewModel.quickAISession?.lastTurn.answer, "床前")
        XCTAssertEqual(viewModel.quickAISession?.isStreaming, true)
        XCTAssertTrue(viewModel.isExpanded)

        viewModel.stopQuickAI()
        await task.value
    }

    func testAnswerToCopyExcludesThinking() async throws {
        let viewModel = makeQuickAIViewModel(
            answerer: StubAIAnswerer(deltas: ["<think>推理", "</think>", "答案"])
        )
        viewModel.toggleQuickAIMode()
        viewModel.query = "问题"
        try await XCTUnwrap(viewModel.startQuickAI()).value

        XCTAssertEqual(viewModel.quickAISession?.lastTurn.answer, "<think>推理</think>答案")
        XCTAssertEqual(viewModel.quickAIAnswerToCopy, "答案")
    }

    /// 复制最后一条回答：新的一轮还没有可见内容（尚未到达或仍在推理）时复制上一条。
    func testAnswerToCopyIsLatestVisibleAnswer() {
        var session = QuickAISession(question: "第一问")
        session.lastTurn.answer = "答一"
        session.lastTurn.state = .finished
        session.append(question: "第二问")
        XCTAssertEqual(session.answerToCopy, "答一")

        session.lastTurn.answer = "<think>推理"
        XCTAssertEqual(session.answerToCopy, "答一")

        session.lastTurn.answer = "<think>推理</think>答二"
        XCTAssertEqual(session.answerToCopy, "答二")
    }

    /// 发给模型的历史只含有可见回答的轮次（输出到一半失败的部分回答也算），回答去掉推理内容，不含最后一轮。
    func testHistoryOnlyIncludesEarlierTurnsWithVisibleAnswers() {
        var session = QuickAISession(question: "第一问")
        session.lastTurn.answer = "<think>推理</think>答一"
        session.lastTurn.state = .finished
        session.append(question: "第二问")
        session.lastTurn.state = .failed("超时")
        session.append(question: "第三问")
        session.lastTurn.answer = "答到一半"
        session.lastTurn.state = .failed("连接中断")
        session.append(question: "第四问")
        session.lastTurn.answer = "正在输出"

        XCTAssertEqual(session.history, [
            AIConversationTurn(question: "第一问", answer: "答一"),
            AIConversationTurn(question: "第三问", answer: "答到一半"),
        ])
    }

    func testScrollQuickAIAnswerOnlyWithSession() async throws {
        let viewModel = makeQuickAIViewModel(answerer: StubAIAnswerer(deltas: ["回答"]))
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
        XCTAssertEqual(session.returnAction(hasDraft: false), .none)
        XCTAssertEqual(session.returnAction(hasDraft: true), .none, "输出期间有草稿也不响应")

        session.lastTurn.state = .finished
        XCTAssertEqual(session.returnAction(hasDraft: false), .retry, "空回答应提示重试")
        XCTAssertEqual(session.returnAction(hasDraft: true), .followUp)

        session.lastTurn.answer = "<think>推理</think>"
        XCTAssertEqual(session.returnAction(hasDraft: false), .retry, "只有思考内容视为空回答")

        session.lastTurn.answer = "答案"
        XCTAssertEqual(session.returnAction(hasDraft: false), .copyAndClose)
        XCTAssertEqual(session.returnAction(hasDraft: true), .followUp)

        session.lastTurn.state = .failed("超时")
        XCTAssertEqual(session.returnAction(hasDraft: false), .retry, "输出到一半失败也应重试")
        XCTAssertEqual(session.returnAction(hasDraft: true), .followUp, "失败后有草稿时追问")

        session.append(question: "追问")
        XCTAssertEqual(session.returnAction(hasDraft: false), .none, "只看最后一轮")
    }

    func testReturnActionTreatsWhitespaceDraftAsEmpty() async throws {
        let viewModel = makeQuickAIViewModel(answerer: StubAIAnswerer(deltas: ["答案"]))
        viewModel.toggleQuickAIMode()
        XCTAssertNil(viewModel.quickAIReturnAction, "尚未提问时回车即提问")

        viewModel.query = "问题"
        try await XCTUnwrap(viewModel.startQuickAI()).value
        viewModel.query = "   "

        XCTAssertEqual(viewModel.quickAIReturnAction, .copyAndClose)
        XCTAssertNil(viewModel.startQuickAI())
    }

    /// 重试只重来最后一轮：沿用这一轮的问题与此前各轮的问答，不新增轮次，输入框中的草稿不变。
    func testRetryRestartsLastTurnWithSameQuestionAndHistory() async throws {
        let answerer = StubAIAnswerer(deltas: ["半"], error: .httpStatus(500, nil))
        let viewModel = makeQuickAIViewModel(answerer: answerer)
        viewModel.toggleQuickAIMode()
        viewModel.query = "第一问"
        try await XCTUnwrap(viewModel.startQuickAI()).value
        viewModel.query = "第二问"
        try await XCTUnwrap(viewModel.startQuickAI()).value
        XCTAssertEqual(viewModel.quickAIReturnAction, .retry)

        viewModel.query = " "
        let retry = try XCTUnwrap(viewModel.retryQuickAI())
        XCTAssertEqual(viewModel.quickAISession?.lastTurn.state, .streaming)
        XCTAssertEqual(viewModel.quickAISession?.lastTurn.answer, "")
        XCTAssertEqual(viewModel.query, " ")
        await retry.value

        XCTAssertEqual(viewModel.quickAISession?.turns.map(\.question), ["第一问", "第二问"])
        XCTAssertEqual(answerer.recorder.questions, ["第一问", "第二问", "第二问"])
        let earlierTurns = [AIConversationTurn(question: "第一问", answer: "半")]
        XCTAssertEqual(answerer.recorder.histories, [[], earlierTurns, earlierTurns], "中途失败的部分回答也发送")
    }

    func testRetryRequiresFinishedConversation() {
        let viewModel = makeQuickAIViewModel(answerer: StubAIAnswerer(deltas: []))
        viewModel.toggleQuickAIMode()

        XCTAssertNil(viewModel.retryQuickAI())
        XCTAssertNil(viewModel.quickAISession)
    }

    func testMarkQuickAIAnswerCopied() async throws {
        let viewModel = makeQuickAIViewModel(answerer: StubAIAnswerer(deltas: ["答案"]))
        viewModel.toggleQuickAIMode()
        viewModel.query = "问题"
        try await XCTUnwrap(viewModel.startQuickAI()).value

        viewModel.markQuickAIAnswerCopied()

        XCTAssertEqual(viewModel.quickAISession?.isAnswerCopied, true)
    }

    func testSessionKeepsModelNameFromSettingsForTitle() async throws {
        let settingsStore = MemoryAppSettingsStore(initial: AppSettings(
            quickAIBaseURL: "https://api.openai.com/v1",
            quickAIModel: " gpt-4o-mini\n"
        ))
        let viewModel = makeQuickAIViewModel(answerer: StubAIAnswerer(deltas: ["答案"]), settingsStore: settingsStore)
        viewModel.toggleQuickAIMode()
        viewModel.query = "问题"
        try await XCTUnwrap(viewModel.startQuickAI()).value

        settingsStore.save(AppSettings(quickAIBaseURL: "https://api.openai.com/v1", quickAIModel: "gpt-5"))
        viewModel.query = "追问"
        try await XCTUnwrap(viewModel.startQuickAI()).value

        XCTAssertEqual(viewModel.quickAISession?.modelName, "gpt-4o-mini", "标题沿用开始对话时的模型名")
    }

    func testPrepareForPresentationResetsQuickAISession() async throws {
        let viewModel = makeQuickAIViewModel(answerer: StubAIAnswerer(deltas: ["回答"]))
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

    // MARK: - 流式合并上屏

    /// 增量攒成一批上屏，已上屏的不会重复交出；丢弃的增量不再上屏。
    func testStreamingTextBufferMergesDeltasAndDiscards() {
        var flushed: [String] = []
        let buffer = StreamingTextBuffer(interval: .seconds(60)) { flushed.append($0) }

        buffer.append("你")
        buffer.append("好")
        buffer.flush()
        buffer.flush()
        XCTAssertEqual(flushed, ["你好"])

        buffer.append("丢弃")
        buffer.discard()
        buffer.flush()
        XCTAssertEqual(flushed, ["你好"])
    }

    // MARK: - 设置

    func testUserDefaultsStoreRoundTripsQuickAISettings() throws {
        let suiteName = "OITests-QuickAI-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = AppSettings(
            quickAIBaseURL: "http://localhost:11434/v1",
            quickAIModel: "qwen2.5",
            quickAIReasoningEffort: "medium"
        )

        UserDefaultsAppSettingsStore(defaults: defaults).save(settings)

        XCTAssertEqual(UserDefaultsAppSettingsStore(defaults: defaults).load(), settings)
    }

    func testSettingsViewModelSavesAndReloadsAPIKey() {
        let keyStore = MemoryAPIKeyStore(initial: "sk-old")
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

    func testKeychainAPIKeyStoreRoundTripsAndDeletes() {
        let testService = "OITests.KeychainAPIKeyStore.\(UUID().uuidString)"
        let store = KeychainAPIKeyStore(service: testService)
        defer { store.save(nil) }

        XCTAssertNil(store.load())

        store.save("sk-keychain-test")
        XCTAssertEqual(store.load(), "sk-keychain-test")

        store.save("sk-keychain-updated")
        XCTAssertEqual(store.load(), "sk-keychain-updated")

        store.save("  ")
        XCTAssertNil(store.load())
    }

    func testSettingsViewModelKeepsTranslationAPIKeySeparate() {
        let quickAIKeyStore = MemoryAPIKeyStore(initial: "sk-quick")
        let translatorKeyStore = MemoryAPIKeyStore(initial: "sk-translate")
        let viewModel = SettingsViewModel(
            settingsStore: MemoryAppSettingsStore(),
            loginItemController: StubLoginItemController(),
            quickAIKeyStore: quickAIKeyStore,
            translatorKeyStore: translatorKeyStore
        )

        viewModel.reloadQuickAIAPIKey()
        viewModel.reloadTranslationAPIKey()
        XCTAssertEqual(viewModel.quickAIAPIKey, "sk-quick")
        XCTAssertEqual(viewModel.translationAPIKey, "sk-translate")

        viewModel.setTranslationAPIKey(" sk-new ")
        XCTAssertEqual(translatorKeyStore.load(), "sk-translate", "输入过程中不应写入")
        viewModel.commitTranslationAPIKey()
        XCTAssertEqual(translatorKeyStore.load(), "sk-new")

        viewModel.setTranslationAPIKey("")
        viewModel.commitTranslationAPIKey()
        XCTAssertNil(translatorKeyStore.load())
        XCTAssertEqual(quickAIKeyStore.load(), "sk-quick", "翻译密钥的改动不影响 Quick AI")
    }

    /// 升级前两者共用密钥：翻译密钥首次读取时复制 Quick AI 的密钥，此后互不影响，清空后也不再复制。
    func testKeychainTranslatorKeyStoreCopiesQuickAIKeyOnce() {
        let testService = "OITests.KeychainAPIKeyStore.\(UUID().uuidString)"
        defer { deleteKeychainItems(service: testService) }
        let quickAIStore = KeychainAPIKeyStore(service: testService)
        quickAIStore.save("sk-shared")

        XCTAssertEqual(makeTranslatorKeyStore(service: testService).load(), "sk-shared")

        quickAIStore.save("sk-quick-new")
        XCTAssertEqual(makeTranslatorKeyStore(service: testService).load(), "sk-shared", "复制后不再跟随 Quick AI")

        makeTranslatorKeyStore(service: testService).save(nil)
        XCTAssertNil(makeTranslatorKeyStore(service: testService).load(), "清空后不应再次复制 Quick AI 的密钥")
        XCTAssertEqual(quickAIStore.load(), "sk-quick-new")
    }

    /// 全新安装时两者都没有密钥：之后填写的 Quick AI 密钥不会被复制给翻译。
    func testKeychainTranslatorKeyStoreDoesNotCopyLaterQuickAIKey() {
        let testService = "OITests.KeychainAPIKeyStore.\(UUID().uuidString)"
        defer { deleteKeychainItems(service: testService) }

        XCTAssertNil(makeTranslatorKeyStore(service: testService).load())

        KeychainAPIKeyStore(service: testService).save("sk-quick")
        XCTAssertNil(makeTranslatorKeyStore(service: testService).load())
    }

    // MARK: - 辅助方法

    /// 每次新建实例，避免内存缓存掩盖钥匙串中的实际内容。
    private func makeTranslatorKeyStore(service: String) -> KeychainAPIKeyStore {
        KeychainAPIKeyStore(
            service: service,
            account: KeychainAPIKeyStore.translatorAccount,
            initialValueAccount: KeychainAPIKeyStore.quickAIAccount
        )
    }

    /// 翻译账户清空时保留空值占位，测试结束按 service 删除全部条目。
    private func deleteKeychainItems(service: String) {
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ] as CFDictionary)
    }

    private func configuredSettingsStore() -> MemoryAppSettingsStore {
        MemoryAppSettingsStore(initial: AppSettings(
            quickAIBaseURL: "https://api.openai.com/v1",
            quickAIModel: "gpt-4o-mini"
        ))
    }

    private func makeQuickAIViewModel(
        answerer: any AIAnswering,
        settingsStore: MemoryAppSettingsStore? = nil
    ) -> LauncherViewModel {
        let settingsStore = settingsStore ?? configuredSettingsStore()
        return LauncherViewModel(
            discoverApplications: DiscoverApplications(catalog: StubAppCatalog(descriptors: [])),
            launchApplication: LaunchApplication(launcher: StubApplicationLauncher()),
            askQuickAI: AskQuickAI(
                answerer: answerer,
                settingsStore: settingsStore,
                keyStore: MemoryAPIKeyStore()
            ),
            settingsStore: settingsStore
        )
    }
}

/// 记录问答端口每次收到的提问、此前各轮的问答与接口配置。
private final class QuickAIRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedQuestions: [String] = []
    private var storedHistories: [[AIConversationTurn]] = []
    private var storedConfigurations: [AIEndpointConfiguration] = []

    var questions: [String] {
        lock.withLock { storedQuestions }
    }

    var histories: [[AIConversationTurn]] {
        lock.withLock { storedHistories }
    }

    var configurations: [AIEndpointConfiguration] {
        lock.withLock { storedConfigurations }
    }

    func record(question: String, history: [AIConversationTurn], configuration: AIEndpointConfiguration) {
        lock.withLock {
            storedQuestions.append(question)
            storedHistories.append(history)
            storedConfigurations.append(configuration)
        }
    }
}

/// 依次产出给定的增量后结束（或以 `error` 失败）。
private struct StubAIAnswerer: AIAnswering {
    let deltas: [String]
    let error: AIClientError?
    let recorder = QuickAIRequestRecorder()

    init(deltas: [String], error: AIClientError? = nil) {
        self.deltas = deltas
        self.error = error
    }

    func streamAnswer(
        to question: String,
        history: [AIConversationTurn],
        systemPrompt: String,
        configuration: AIEndpointConfiguration
    ) -> AsyncThrowingStream<String, Error> {
        recorder.record(question: question, history: history, configuration: configuration)
        return AsyncThrowingStream { continuation in
            for delta in deltas {
                continuation.yield(delta)
            }
            continuation.finish(throwing: error)
        }
    }
}

/// 产出一段增量后一直不结束：模拟仍在生成中的回答。保留续体，流只在消费方取消时结束。
private final class HangingAIAnswerer: AIAnswering, @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [AsyncThrowingStream<String, Error>.Continuation] = []

    func streamAnswer(
        to question: String,
        history: [AIConversationTurn],
        systemPrompt: String,
        configuration: AIEndpointConfiguration
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            lock.withLock { continuations.append(continuation) }
            continuation.yield("床前")
        }
    }
}
