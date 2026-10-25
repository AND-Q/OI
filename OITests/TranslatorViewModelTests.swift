import AppKit
import AVFoundation
import Foundation
import XCTest

@testable import OI

/// 翻译气泡的视图模型：取词、修改原文、切换语言与朗读。
@MainActor
final class TranslatorViewModelTests: TranslatorTestCase {
    // MARK: - 视图模型：取词

    func testShortcutTranslatesSelectionAtItsPosition() async throws {
        let rect = CGRect(x: 100, y: 200, width: 80, height: 18)
        let viewModel = makeTranslatorViewModel(
            capturer: StubTextCapturer(
                selection: CapturedText(text: "Hello", source: .selection, screenRect: rect),
                clipboard: CapturedText(text: "剪贴板", source: .clipboard, screenRect: nil)
            )
        )

        let presentation = await viewModel.captureFromShortcut()

        XCTAssertEqual(presentation, TranslatorPresentation(anchorRect: rect))
        XCTAssertEqual(viewModel.session?.sourceText, "Hello")
        XCTAssertEqual(viewModel.session?.source, .selection)
        XCTAssertEqual(viewModel.session?.targetLanguage, .simplifiedChinese)
        XCTAssertNil(viewModel.notice)
        try await waitUntil { viewModel.session?.state == .finished }
        XCTAssertEqual(viewModel.translationToCopy, "你好")
    }

    func testShortcutFallsBackToClipboardWithoutSelection() async {
        let viewModel = makeTranslatorViewModel(
            capturer: StubTextCapturer(clipboard: CapturedText(text: "copied", source: .clipboard, screenRect: nil))
        )

        let presentation = await viewModel.captureFromShortcut()

        XCTAssertEqual(presentation, TranslatorPresentation(anchorRect: nil))
        XCTAssertEqual(viewModel.session?.sourceText, "copied")
        XCTAssertEqual(viewModel.session?.source, .clipboard)
        XCTAssertNil(viewModel.notice)
    }

    /// 未授权时读不到选区：直接翻译剪贴板，并提示原因，避免用户误以为翻译的是选中的文字。
    func testShortcutWithoutAccessibilityTranslatesClipboardWithNotice() async {
        let viewModel = makeTranslatorViewModel(
            capturer: StubTextCapturer(
                selection: CapturedText(text: "selected", source: .selection, screenRect: nil),
                clipboard: CapturedText(text: "copied", source: .clipboard, screenRect: nil)
            ),
            environment: MemoryTranslatorEnvironment(isAccessibilityTrusted: false)
        )

        _ = await viewModel.captureFromShortcut()

        XCTAssertEqual(viewModel.session?.sourceText, "copied")
        XCTAssertEqual(viewModel.notice, .clipboardUsedWithoutAccessibility)
    }

    func testShortcutWithNothingToTranslateShowsNotice() async {
        let trusted = makeTranslatorViewModel()
        let untrusted = makeTranslatorViewModel(environment: MemoryTranslatorEnvironment(isAccessibilityTrusted: false))

        let presentation = await trusted.captureFromShortcut()
        _ = await untrusted.captureFromShortcut()

        XCTAssertEqual(presentation, TranslatorPresentation(anchorRect: nil))
        XCTAssertNil(trusted.session)
        XCTAssertEqual(trusted.notice, .nothingToTranslate)
        XCTAssertEqual(untrusted.notice, .accessibilityRequired)
    }

    func testForceTouchRequiresSettingAndPermission() async {
        let selector = RecordingWordSelector(selected: CapturedText(text: "word", source: .word, screenRect: nil))
        var disabled = Self.configuredSettings
        disabled.isForceTouchTranslationEnabled = false
        let disabledViewModel = makeTranslatorViewModel(
            capturer: StubTextCapturer(lookupWithoutWord: .unavailable),
            wordSelector: selector,
            settings: disabled
        )
        let untrustedViewModel = makeTranslatorViewModel(
            capturer: StubTextCapturer(lookupWithoutWord: .unavailable),
            wordSelector: selector,
            environment: MemoryTranslatorEnvironment(isAccessibilityTrusted: false)
        )

        let disabledResult = await disabledViewModel.captureFromForceTouch(at: .zero)
        let untrustedResult = await untrustedViewModel.captureFromForceTouch(at: .zero)

        XCTAssertNil(disabledResult)
        XCTAssertNil(untrustedResult)
        XCTAssertNil(disabledViewModel.session)
        XCTAssertNil(untrustedViewModel.session)
        XCTAssertEqual(selector.points, [], "功能关闭或未获授权时不模拟双击")
    }

    /// 用力点按只翻译点按处的单词：按在选区上也取单词，选中的文字交给翻译快捷键。
    func testForceTouchTranslatesWordEvenOnSelection() async {
        let selectionRect = CGRect(x: 100, y: 200, width: 80, height: 18)
        let wordRect = CGRect(x: 110, y: 200, width: 30, height: 18)
        let viewModel = makeTranslatorViewModel(
            capturer: StubTextCapturer(
                selection: CapturedText(text: "selected text", source: .selection, screenRect: selectionRect),
                wordAtPoint: CapturedText(text: "word", source: .word, screenRect: wordRect)
            )
        )

        let presentation = await viewModel.captureFromForceTouch(at: CGPoint(x: 120, y: 205))

        XCTAssertEqual(presentation, TranslatorPresentation(anchorRect: wordRect))
        XCTAssertEqual(viewModel.session?.sourceText, "word")
        XCTAssertEqual(viewModel.session?.source, .word)
    }

    /// 取不到单词时也不翻译选区：点按处不是文字、或双击没有选中单词时都不弹出气泡。
    func testForceTouchWithoutWordIgnoresSelection() async {
        let selection = CapturedText(text: "selected text", source: .selection, screenRect: nil)
        let notOnText = makeTranslatorViewModel(
            capturer: StubTextCapturer(selection: selection, lookupWithoutWord: .notOnText)
        )
        let selector = RecordingWordSelector()
        let nothingSelected = makeTranslatorViewModel(
            capturer: StubTextCapturer(selection: selection, lookupWithoutWord: .unavailable),
            wordSelector: selector
        )

        let notOnTextResult = await notOnText.captureFromForceTouch(at: .zero)
        let nothingSelectedResult = await nothingSelected.captureFromForceTouch(at: .zero)

        XCTAssertNil(notOnTextResult)
        XCTAssertNil(notOnText.session)
        XCTAssertEqual(selector.points, [.zero])
        XCTAssertNil(nothingSelectedResult)
        XCTAssertNil(nothingSelected.session)
    }

    func testForceTouchOnNonTextDoesNothing() async {
        let viewModel = makeTranslatorViewModel()

        let presentation = await viewModel.captureFromForceTouch(at: CGPoint(x: 10, y: 10))

        XCTAssertNil(presentation)
        XCTAssertNil(viewModel.session)
        XCTAssertNil(viewModel.notice)
    }

    /// 应用不提供点按处的文字位置（如 VS Code、Chrome）时模拟双击选词，气泡贴着选中的单词。
    func testForceTouchSelectsWordByDoubleClickWhenTextPositionIsUnavailable() async {
        let selected = CapturedText(text: "模型", source: .word, screenRect: CGRect(x: 90, y: 95, width: 30, height: 18))
        let selector = RecordingWordSelector(selected: selected)
        let viewModel = makeTranslatorViewModel(
            capturer: StubTextCapturer(lookupWithoutWord: .unavailable),
            wordSelector: selector
        )

        let presentation = await viewModel.captureFromForceTouch(at: CGPoint(x: 100, y: 100))

        XCTAssertEqual(presentation, TranslatorPresentation(anchorRect: selected.screenRect))
        XCTAssertEqual(viewModel.session?.sourceText, "模型")
        XCTAssertEqual(viewModel.session?.source, .word)
        XCTAssertEqual(selector.points, [CGPoint(x: 100, y: 100)])
    }

    /// 应用能核对位置、点按处却不是文字（如空白处）时不双击，以免选中附近的词。
    func testForceTouchDoesNotDoubleClickWhenPointIsNotOnText() async {
        let selector = RecordingWordSelector(selected: CapturedText(text: "nearby", source: .word, screenRect: nil))
        let viewModel = makeTranslatorViewModel(
            capturer: StubTextCapturer(lookupWithoutWord: .notOnText),
            wordSelector: selector
        )

        let presentation = await viewModel.captureFromForceTouch(at: CGPoint(x: 100, y: 100))

        XCTAssertNil(presentation)
        XCTAssertNil(viewModel.session)
        XCTAssertEqual(selector.points, [])
    }

    func testForceTouchPrefersAccessibilityWordOverDoubleClick() async {
        let selector = RecordingWordSelector(selected: CapturedText(text: "selected", source: .word, screenRect: nil))
        let viewModel = makeTranslatorViewModel(
            capturer: StubTextCapturer(wordAtPoint: CapturedText(text: "word", source: .word, screenRect: nil)),
            wordSelector: selector
        )

        _ = await viewModel.captureFromForceTouch(at: .zero)

        XCTAssertEqual(viewModel.session?.sourceText, "word")
        XCTAssertEqual(selector.points, [])
    }

    // MARK: - 视图模型：修改原文与切换语言

    func testEditingSourceReturnsToDraftAndRedetectsLanguage() async throws {
        let answerer = RecordingAnswerer(deltas: ["译文"])
        let viewModel = makeTranslatorViewModel(
            capturer: StubTextCapturer(wordAtPoint: CapturedText(text: "Hello", source: .word, screenRect: nil)),
            answerer: answerer,
            detector: StubLanguageDetector(codes: ["Hello": "en", "你好": "zh-Hans"])
        )
        _ = await viewModel.captureFromForceTouch(at: .zero)
        try await waitUntil { viewModel.session?.state == .finished }

        viewModel.updateSourceText("你好")

        XCTAssertEqual(viewModel.session?.state, .draft)
        XCTAssertEqual(viewModel.session?.translation, "")
        XCTAssertEqual(viewModel.session?.returnAction, .translate)
        XCTAssertNil(viewModel.translationToCopy)

        viewModel.translateCurrentSource()
        try await waitUntil { viewModel.session?.state == .finished }

        XCTAssertEqual(viewModel.session?.sourceLanguageCode, "zh-Hans")
        XCTAssertEqual(viewModel.session?.targetLanguage, .english)
        XCTAssertEqual(answerer.recorder.questions, ["Hello", "你好"])
        XCTAssertEqual(answerer.recorder.prompts.last, TranslateText.systemPrompt(for: .english))
    }

    func testSelectedTargetLanguageRetranslatesAndSurvivesEdits() async throws {
        let answerer = RecordingAnswerer(deltas: ["译文"])
        let viewModel = makeTranslatorViewModel(
            capturer: StubTextCapturer(wordAtPoint: CapturedText(text: "Hello", source: .word, screenRect: nil)),
            answerer: answerer,
            detector: StubLanguageDetector(codes: ["Hello": "en", "你好": "zh-Hans"])
        )
        _ = await viewModel.captureFromForceTouch(at: .zero)
        try await waitUntil { viewModel.session?.state == .finished }

        viewModel.selectTargetLanguage(.japanese)
        XCTAssertEqual(viewModel.session?.state, .streaming)
        try await waitUntil { viewModel.session?.state == .finished }
        XCTAssertEqual(answerer.recorder.prompts.last, TranslateText.systemPrompt(for: .japanese))

        viewModel.updateSourceText("你好")
        viewModel.translateCurrentSource()
        try await waitUntil { viewModel.session?.state == .finished }

        XCTAssertEqual(viewModel.session?.targetLanguage, .japanese, "手动选择的语言在修改原文后仍沿用")
        XCTAssertEqual(answerer.recorder.prompts.last, TranslateText.systemPrompt(for: .japanese))
    }

    func testFailedTranslationShowsReasonAndRetries() async throws {
        let viewModel = makeTranslatorViewModel(
            capturer: StubTextCapturer(wordAtPoint: CapturedText(text: "Hello", source: .word, screenRect: nil)),
            settings: AppSettings()
        )

        _ = await viewModel.captureFromForceTouch(at: .zero)
        try await waitUntil { viewModel.session?.returnAction == .retry }

        guard case .failed(let message)? = viewModel.session?.state else {
            return XCTFail("应展示未配置提示")
        }
        XCTAssertTrue(message.contains("设置… → 划词翻译"))

        viewModel.translateCurrentSource()
        XCTAssertEqual(viewModel.session?.state, .streaming)
    }

    func testStopKeepsPartialTranslationAndResetClears() async throws {
        let viewModel = makeTranslatorViewModel(
            capturer: StubTextCapturer(wordAtPoint: CapturedText(text: "poem", source: .word, screenRect: nil)),
            answerer: HangingAnswerer()
        )
        _ = await viewModel.captureFromForceTouch(at: .zero)
        try await waitUntil { viewModel.session?.translation.isEmpty == false }

        viewModel.stopTranslation()

        XCTAssertEqual(viewModel.session?.translation, "部分")
        XCTAssertEqual(viewModel.session?.state, .finished)

        viewModel.reset()

        XCTAssertNil(viewModel.session)
        XCTAssertNil(viewModel.notice)
    }

    func testTranslationToCopyExcludesThinkingAndMarksCopied() async throws {
        let viewModel = makeTranslatorViewModel(
            capturer: StubTextCapturer(wordAtPoint: CapturedText(text: "Hello", source: .word, screenRect: nil)),
            answerer: RecordingAnswerer(deltas: ["<think>推理", "</think>", "你好"])
        )
        _ = await viewModel.captureFromForceTouch(at: .zero)
        try await waitUntil { viewModel.session?.state == .finished }

        XCTAssertEqual(viewModel.translationToCopy, "你好")
        viewModel.markCopied()
        XCTAssertEqual(viewModel.session?.isCopied, true)
    }

    func testReturnActionFollowsSessionState() {
        var session = TranslatorSession(
            sourceText: "Hello",
            source: .word,
            sourceLanguageCode: "en",
            targetLanguage: .simplifiedChinese
        )
        XCTAssertEqual(session.returnAction, .none, "输出期间不响应回车")

        session.state = .finished
        XCTAssertEqual(session.returnAction, .retry, "没有译文时重试")

        session.translation = "<think>推理</think>"
        XCTAssertEqual(session.returnAction, .retry, "只有思考内容视为没有译文")

        session.translation = "你好"
        XCTAssertEqual(session.returnAction, .copyAndClose)

        session.state = .failed("超时")
        XCTAssertEqual(session.returnAction, .retry)

        session.state = .draft
        XCTAssertEqual(session.returnAction, .translate)

        session.sourceText = "  "
        XCTAssertEqual(session.returnAction, .none, "原文为空时不翻译")

        session.state = .recognizing
        XCTAssertEqual(session.returnAction, .none, "截图识别期间不响应回车")
    }

    func testSourceLanguageNameUsesSupportedAndSystemNames() {
        func name(_ code: String?) -> String? {
            TranslatorSession(
                sourceText: "x",
                source: .word,
                sourceLanguageCode: code,
                targetLanguage: .simplifiedChinese
            ).sourceLanguageName
        }

        XCTAssertEqual(name("en"), "英语")
        XCTAssertEqual(name("zh-Hant"), "繁体中文")
        XCTAssertNotNil(name("sw"), "不在支持列表中的语言使用系统的本地化名称")
        XCTAssertNil(name(nil))
    }

    // MARK: - 朗读

    /// ⌘⇧S 用原文语言的发音人朗读去掉首尾空白的原文，读完后复位。
    func testSpeechReadsSourceInDetectedLanguage() async throws {
        let speaker = RecordingTextSpeaker()
        let viewModel = makeTranslatorViewModel(
            capturer: StubTextCapturer(selection: CapturedText(text: "  Hello  ", source: .selection, screenRect: nil)),
            speaker: speaker
        )
        _ = await viewModel.captureFromShortcut()

        viewModel.toggleSpeech()
        XCTAssertTrue(viewModel.isSpeaking)
        try await waitUntil { speaker.requests.count == 1 }
        XCTAssertEqual(speaker.requests, [RecordingTextSpeaker.Request(text: "Hello", languageCode: "en")])

        speaker.finishSpeaking()
        try await waitUntil { !viewModel.isSpeaking }
        XCTAssertEqual(speaker.cancelledCount, 0)
    }

    /// 修改原文后尚未重新翻译时，按修改后的原文识别语言，选用对应的发音人。
    func testSpeechAfterEditingUsesLanguageOfEditedSource() async throws {
        let speaker = RecordingTextSpeaker()
        let viewModel = makeTranslatorViewModel(
            capturer: StubTextCapturer(selection: CapturedText(text: "Hello", source: .selection, screenRect: nil)),
            detector: StubLanguageDetector(codes: ["Hello": "en", "Bonjour": "fr"]),
            speaker: speaker
        )
        _ = await viewModel.captureFromShortcut()
        viewModel.updateSourceText("Bonjour")

        viewModel.toggleSpeech()
        try await waitUntil { speaker.requests.count == 1 }
        XCTAssertEqual(speaker.requests, [RecordingTextSpeaker.Request(text: "Bonjour", languageCode: "fr")])

        speaker.finishSpeaking()
        try await waitUntil { !viewModel.isSpeaking }
    }

    /// 朗读中再按一次即停止；重新取词或气泡隐藏时也停止朗读上一段。
    func testSpeechStopsWhenToggledAgainOrSessionChanges() async throws {
        let speaker = RecordingTextSpeaker()
        let viewModel = makeTranslatorViewModel(
            capturer: StubTextCapturer(selection: CapturedText(text: "Hello", source: .selection, screenRect: nil)),
            speaker: speaker
        )
        _ = await viewModel.captureFromShortcut()

        viewModel.toggleSpeech()
        try await waitUntil { speaker.requests.count == 1 }
        viewModel.toggleSpeech()
        XCTAssertFalse(viewModel.isSpeaking)
        try await waitUntil { speaker.cancelledCount == 1 }

        viewModel.toggleSpeech()
        try await waitUntil { speaker.requests.count == 2 }
        _ = await viewModel.captureFromShortcut()
        XCTAssertFalse(viewModel.isSpeaking, "重新取词即停止朗读上一段")
        try await waitUntil { speaker.cancelledCount == 2 }

        viewModel.toggleSpeech()
        try await waitUntil { speaker.requests.count == 3 }
        viewModel.reset()
        XCTAssertFalse(viewModel.isSpeaking)
        try await waitUntil { speaker.cancelledCount == 3 }
    }

    /// 没有原文时不朗读：只有提示，或截图翻译还在识别文字。
    func testSpeechIgnoredWithoutSourceText() async {
        let speaker = RecordingTextSpeaker()
        let viewModel = makeTranslatorViewModel(speaker: speaker)

        _ = await viewModel.captureFromShortcut()
        viewModel.toggleSpeech()
        XCTAssertEqual(viewModel.notice, .nothingToTranslate)
        XCTAssertFalse(viewModel.isSpeaking)

        _ = viewModel.translateScreenRegion(CGRect(x: 0, y: 0, width: 200, height: 40), in: Self.snapshot)
        viewModel.toggleSpeech()
        XCTAssertEqual(viewModel.session?.state, .recognizing)
        XCTAssertFalse(viewModel.isSpeaking)
        XCTAssertTrue(speaker.requests.isEmpty)
    }

    /// 发音人优先该语言最常用的地区：繁体中文用台湾的发音人，不用香港的粤语发音人。本机没装的语言不检查。
    func testSpeakerPicksVoiceOfSourceLanguage() {
        XCTAssertNil(SystemTextSpeaker.voice(for: nil))
        let installed = Set(AVSpeechSynthesisVoice.speechVoices().map(\.language))
        let expectations = ["en": "en-US", "zh-Hans": "zh-CN", "zh-Hant": "zh-TW", "ja": "ja-JP"]
        for (code, language) in expectations where installed.contains(language) {
            XCTAssertEqual(SystemTextSpeaker.voice(for: code)?.language, language, code)
        }
    }
}
