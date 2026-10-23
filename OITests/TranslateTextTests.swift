import AppKit
import AVFoundation
import Foundation
import XCTest

@testable import OI

/// 划词翻译用例：选定翻译方向、提示词与失败映射。
@MainActor
final class TranslateTextTests: TranslatorTestCase {
    // MARK: - 用例

    func testForeignTextTranslatesIntoTargetLanguage() {
        let useCase = makeUseCase(detector: StubLanguageDetector(code: "en"))

        XCTAssertEqual(
            useCase.makeRequest(for: "Hello"),
            TranslationRequest(text: "Hello", sourceLanguageCode: "en", targetLanguage: .simplifiedChinese)
        )
    }

    func testTextInTargetLanguageTranslatesIntoAlternateLanguage() {
        let useCase = makeUseCase(detector: StubLanguageDetector(code: "zh-Hant"))

        XCTAssertEqual(useCase.makeRequest(for: "翻譯").targetLanguage, .english)
    }

    func testCustomLanguagesAndExplicitTarget() {
        let settings = AppSettings(translationTargetLanguage: .japanese, translationAlternateLanguage: .korean)
        let useCase = makeUseCase(detector: StubLanguageDetector(code: "ja"), settings: settings)

        XCTAssertEqual(useCase.makeRequest(for: "こんにちは").targetLanguage, .korean)
        XCTAssertEqual(useCase.makeRequest(for: "こんにちは", target: .french).targetLanguage, .french)
    }

    func testUndetectedTextTranslatesIntoTargetLanguage() {
        let useCase = makeUseCase(detector: StubLanguageDetector(code: nil))

        let request = useCase.makeRequest(for: "1234")

        XCTAssertNil(request.sourceLanguageCode)
        XCTAssertEqual(request.targetLanguage, .simplifiedChinese)
    }

    /// 翻译接口与 Quick AI 分开填写：只填了 Quick AI 的接口也按未配置处理。
    func testTranslateTextThrowsNotConfiguredWithoutRequesting() async {
        let answerer = RecordingAnswerer(deltas: ["不应到达"])
        let useCase = makeUseCase(
            answerer: answerer,
            settings: AppSettings(quickAIBaseURL: "https://api.openai.com/v1", quickAIModel: "gpt-4o-mini")
        )

        do {
            try await useCase.execute(useCase.makeRequest(for: "Hello")) { _ in XCTFail("不应收到增量") }
            XCTFail("应抛出未配置错误")
        } catch {
            XCTAssertEqual(error as? ApplicationError, .aiNotConfigured)
        }
        XCTAssertEqual(answerer.recorder.questions, [])
    }

    func testTranslateTextSendsTranslationPromptAndMapsFailures() async {
        let answerer = RecordingAnswerer(deltas: ["你"], error: AIClientError.server("rate limited"))
        let useCase = makeUseCase(answerer: answerer, detector: StubLanguageDetector(code: "en"))
        var received: [String] = []

        do {
            try await useCase.execute(useCase.makeRequest(for: "Hello")) { received.append($0) }
            XCTFail("应抛出失败错误")
        } catch {
            XCTAssertEqual(error as? ApplicationError, .aiRequestFailed(reason: "rate limited"))
        }
        XCTAssertEqual(received, ["你"])
        XCTAssertEqual(answerer.recorder.questions, ["Hello"])
        XCTAssertEqual(answerer.recorder.prompts, [TranslateText.systemPrompt(for: .simplifiedChinese)])
        XCTAssertTrue(TranslateText.systemPrompt(for: .simplifiedChinese).contains("Simplified Chinese"))
        XCTAssertTrue(
            TranslateText.systemPrompt(for: .simplifiedChinese).contains("one meaning per line"),
            "单词的几个释义每行一个，用分号连在一行里分不清是几个释义"
        )
        XCTAssertTrue(
            TranslateText.systemPrompt(for: .simplifiedChinese).contains("Start each line with the part of speech"),
            "单词的每个释义在行首标出词性"
        )
        XCTAssertTrue(
            TranslateText.systemPrompt(for: .simplifiedChinese).contains("If the whole text is a single code identifier"),
            "整段原文只是一个代码标识符时拆成词组翻译，不当作代码原样返回"
        )
        XCTAssertTrue(
            TranslateText.systemPrompt(for: .simplifiedChinese).contains("translate it into one natural"),
            "短语默认只给一个译文，意思明显不同时才分行列出"
        )
    }

    func testTranslateTextUsesTranslatorEndpointAndKey() async throws {
        let answerer = RecordingAnswerer(deltas: ["你好"])
        let useCase = TranslateText(
            answerer: answerer,
            languageDetector: StubLanguageDetector(code: "en"),
            settingsStore: MemoryAppSettingsStore(initial: AppSettings(
                quickAIBaseURL: "https://api.openai.com/v1",
                quickAIModel: "gpt-4o",
                quickAIReasoningEffort: "high",
                translationBaseURL: "http://localhost:11434/v1",
                translationModel: "qwen2.5",
                translationReasoningEffort: "low"
            )),
            keyStore: MemoryAPIKeyStore(initial: "sk-translate")
        )

        try await useCase.execute(useCase.makeRequest(for: "Hello")) { _ in }

        let expected = try XCTUnwrap(AIEndpointConfiguration(
            baseURLString: "http://localhost:11434/v1",
            model: "qwen2.5",
            apiKey: "sk-translate",
            reasoningEffort: "low"
        ))
        XCTAssertEqual(answerer.recorder.configurations, [expected])
    }
}
