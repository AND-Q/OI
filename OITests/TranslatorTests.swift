import AppKit
import AVFoundation
import Foundation
import XCTest

@testable import OI

@MainActor
final class TranslatorTests: XCTestCase {
    private static let configuredSettings = AppSettings(
        translationBaseURL: "https://api.openai.com/v1",
        translationModel: "gpt-4o-mini"
    )
    /// 截图翻译测试用的定格画面：识别由桩按选区返回文字，不读取画面。
    private static let snapshot = ScreenSnapshot(displays: [])

    // MARK: - Language

    func testTranslationLanguageMatchesDetectedCodes() {
        XCTAssertEqual(TranslationLanguage(languageCode: "zh-Hant"), .traditionalChinese)
        XCTAssertEqual(TranslationLanguage(languageCode: "zh"), .simplifiedChinese)
        XCTAssertEqual(TranslationLanguage(languageCode: "pt-BR"), .portuguese)
        XCTAssertNil(TranslationLanguage(languageCode: "sw"))
        XCTAssertTrue(TranslationLanguage.simplifiedChinese.isSameLanguage(as: "zh-Hant"), "简繁同属中文")
        XCTAssertFalse(TranslationLanguage.english.isSameLanguage(as: "es"))
    }

    // MARK: - Language detection

    func testDetectorSplitsIdentifiersIntoWords() {
        XCTAssertEqual(NaturalLanguageDetector.words(in: "reduceKernel"), ["reduce", "Kernel"])
        XCTAssertEqual(NaturalLanguageDetector.words(in: "reduce_kernel"), ["reduce", "kernel"])
        XCTAssertEqual(NaturalLanguageDetector.words(in: "reduce-kernel"), ["reduce", "kernel"])
        XCTAssertEqual(NaturalLanguageDetector.words(in: "XMLHttpRequest"), ["XML", "Http", "Request"])
        XCTAssertEqual(NaturalLanguageDetector.words(in: "utf8String"), ["utf", "String"])
        XCTAssertEqual(NaturalLanguageDetector.words(in: "调用 getUserInfo 接口"), ["get", "User", "Info"], "汉字不计入单词")
    }

    /// 代码标识符与短单词缺少上下文，模型会把 reduceKernel 判为丹麦语：纯 ASCII 字母的短文本按英语。
    func testDetectorTreatsIdentifiersAndShortASCIITextAsEnglish() {
        let detector = NaturalLanguageDetector()
        let texts = [
            "reduceKernel", "reduce_kernel", "REDUCE_KERNEL", "reduce-kernel", "XMLHttpRequest",
            "getUserInfoByIdentifier", "kernel", "Die", "gift", "chat", "Hello world", "reduce kernel size"
        ]

        for text in texts {
            XCTAssertEqual(detector.dominantLanguageCode(of: text), "en", text)
        }
    }

    /// 较长的纯 ASCII 文本仍以英语为主，模型很有把握时才判为其他语言。
    func testDetectorKeepsLongerASCIITextEnglishUnlessConfidentlyForeign() {
        let detector = NaturalLanguageDetector()

        XCTAssertEqual(detector.dominantLanguageCode(of: "Returns the index of the largest element in the buffer"), "en")
        XCTAssertEqual(detector.dominantLanguageCode(of: "The city of 北京 is very large and crowded today"), "en", "英文中夹杂少量汉字")
        XCTAssertEqual(detector.dominantLanguageCode(of: "je ne sais pas pourquoi elle est partie si vite ce matin"), "fr")
    }

    /// 只有汉字的短词不能判为日语；中文里夹杂英文术语与标识符时仍按中文。
    func testDetectorTreatsHanTextWithoutKanaAsChinese() {
        let detector = NaturalLanguageDetector()
        let texts = ["你好", "東京", "注意事项", "繁體中文", "调用 reduceKernel 接口", "用 Python 写 web server"]

        for text in texts {
            let code = detector.dominantLanguageCode(of: text)
            XCTAssertTrue(TranslationLanguage.simplifiedChinese.isSameLanguage(as: code ?? ""), "\(text)：\(code ?? "nil")")
        }
    }

    func testDetectorLeavesOtherScriptsToRecognizer() {
        let detector = NaturalLanguageDetector()

        XCTAssertEqual(detector.dominantLanguageCode(of: "東京に行きます"), "ja", "含假名即为日文")
        XCTAssertEqual(detector.dominantLanguageCode(of: "안녕하세요"), "ko")
        XCTAssertEqual(detector.dominantLanguageCode(of: "Где находится вокзал?"), "ru")
        XCTAssertNil(detector.dominantLanguageCode(of: "1234 + 5678"), "没有字母时无从判断")
    }

    /// 识别结果决定气泡顶部的语言与翻译方向：标识符显示「英语 → 简体中文」，中文译为英语。
    func testDetectedLanguageDrivesTranslationDirection() {
        let useCase = TranslateText(
            answerer: RecordingAnswerer(deltas: []),
            languageDetector: NaturalLanguageDetector(),
            settingsStore: MemoryAppSettingsStore(initial: Self.configuredSettings),
            keyStore: MemoryQuickAIKeyStore()
        )

        let identifier = useCase.makeRequest(for: "reduceKernel")
        let chinese = useCase.makeRequest(for: "归约内核")

        XCTAssertEqual(identifier.sourceLanguageCode, "en")
        XCTAssertEqual(identifier.targetLanguage, .simplifiedChinese)
        XCTAssertEqual(chinese.targetLanguage, .english)
    }

    // MARK: - Use case

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
            XCTAssertEqual(error as? ApplicationError, .quickAINotConfigured)
        }
        XCTAssertEqual(answerer.recorder.questions, [])
    }

    func testTranslateTextSendsTranslationPromptAndMapsFailures() async {
        let answerer = RecordingAnswerer(deltas: ["你"], error: QuickAIClientError.server("rate limited"))
        let useCase = makeUseCase(answerer: answerer, detector: StubLanguageDetector(code: "en"))
        var received: [String] = []

        do {
            try await useCase.execute(useCase.makeRequest(for: "Hello")) { received.append($0) }
            XCTFail("应抛出失败错误")
        } catch {
            XCTAssertEqual(error as? ApplicationError, .quickAIFailed(reason: "rate limited"))
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
            keyStore: MemoryQuickAIKeyStore(initial: "sk-translate")
        )

        try await useCase.execute(useCase.makeRequest(for: "Hello")) { _ in }

        let expected = try XCTUnwrap(QuickAIConfiguration(
            baseURLString: "http://localhost:11434/v1",
            model: "qwen2.5",
            apiKey: "sk-translate",
            reasoningEffort: "low"
        ))
        XCTAssertEqual(answerer.recorder.configurations, [expected])
    }

    // MARK: - Word boundaries

    func testWordRangeFindsWordAroundOffset() {
        let text = "Hello, wonderful world"

        XCTAssertEqual(AccessibilityTextCapturer.wordRange(in: text, containing: 9), NSRange(location: 7, length: 9))
        XCTAssertEqual(AccessibilityTextCapturer.wordRange(in: text, containing: 0), NSRange(location: 0, length: 5))
        XCTAssertNil(AccessibilityTextCapturer.wordRange(in: text, containing: 5), "标点不是单词")
        XCTAssertNil(AccessibilityTextCapturer.wordRange(in: text, containing: 6), "空格不是单词")
        XCTAssertNil(AccessibilityTextCapturer.wordRange(in: text, containing: 99))
    }

    /// 辅助功能 API 的字符区间以 UTF-16 计，表情等占两个单位的字符之后位置不能错位。
    func testWordRangeUsesUTF16Offsets() {
        XCTAssertEqual(
            AccessibilityTextCapturer.wordRange(in: "👋 hello", containing: 4),
            NSRange(location: 3, length: 5)
        )
    }

    func testWordRangeSegmentsChineseIntoWords() throws {
        let text = "我喜欢翻译软件"

        let range = try XCTUnwrap(AccessibilityTextCapturer.wordRange(in: text, containing: 3))

        XCTAssertTrue(NSLocationInRange(3, range))
        XCTAssertLessThan(range.length, (text as NSString).length, "中文应按词切分，而不是整句作为一个词")
    }

    func testCleanedTrimsWhitespaceAndCapsLength() {
        XCTAssertNil(AccessibilityTextCapturer.cleaned(" \n "))
        XCTAssertEqual(AccessibilityTextCapturer.cleaned("  hi \n"), "hi")
        let long = String(repeating: "a", count: AccessibilityTextCapturer.maximumLength + 10)
        XCTAssertEqual(AccessibilityTextCapturer.cleaned(long)?.count, AccessibilityTextCapturer.maximumLength)
    }

    // MARK: - View model: capture

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

    // MARK: - Double click word selection

    func testAcceptedWordRequiresNewSingleWordUnderPointer() {
        let point = CGPoint(x: 100, y: 100)
        let rect = CGRect(x: 90, y: 95, width: 30, height: 18)
        func selection(_ text: String, _ rect: CGRect? = nil) -> CapturedText {
            CapturedText(text: text, source: .selection, screenRect: rect)
        }
        func accepted(_ selected: CapturedText?, previous: CapturedText? = nil) -> CapturedText? {
            DoubleClickWordSelector.acceptedWord(selected, previous: previous, at: point)
        }

        XCTAssertEqual(accepted(selection("model", rect)), CapturedText(text: "model", source: .word, screenRect: rect))
        XCTAssertEqual(accepted(selection("模型"))?.text, "模型", "取不到选区位置时不核对位置")
        XCTAssertNil(accepted(nil))
        XCTAssertNil(accepted(selection("model", rect), previous: selection("model", rect)), "选区没有变化说明双击没有选中新的词")
        XCTAssertNil(accepted(selection("first\nsecond")), "含换行的不是单个词")
        XCTAssertNil(accepted(selection("——")), "纯标点")
        XCTAssertNil(
            accepted(selection(String(repeating: "a", count: DoubleClickWordSelector.maximumWordLength + 1))),
            "过长的多半是整段"
        )
        XCTAssertNil(accepted(selection("model", CGRect(x: 300, y: 95, width: 30, height: 18))), "选区不在点按处")
    }

    func testCanDoubleClickSkipsFinderControlsAndListRows() {
        func canDoubleClick(_ bundleIdentifier: String, _ roles: [String]) -> Bool {
            DoubleClickWordSelector.canDoubleClick(bundleIdentifier: bundleIdentifier, roles: roles)
        }

        XCTAssertTrue(canDoubleClick("com.google.Chrome", ["AXStaticText", "AXGroup", "AXWebArea", "AXWindow"]))
        XCTAssertTrue(canDoubleClick("com.microsoft.VSCode", ["AXGroup", "AXGroup", "AXWebArea", "AXWindow"]), "自绘区域不是控件")
        XCTAssertTrue(
            canDoubleClick("com.google.Chrome", ["AXStaticText", "AXCell", "AXRow", "AXTable", "AXWebArea"]),
            "网页表格中的文字"
        )
        XCTAssertFalse(canDoubleClick("com.apple.finder", ["AXTextField", "AXGroup"]), "Finder 双击会打开文件")
        XCTAssertFalse(canDoubleClick("com.apple.dock", ["AXGroup"]))
        XCTAssertFalse(canDoubleClick("com.google.Chrome", ["AXStaticText", "AXLink", "AXGroup", "AXWebArea"]), "链接中的文字")
        XCTAssertFalse(canDoubleClick("com.google.Chrome", ["AXButton", "AXGroup", "AXWindow"]))
        XCTAssertFalse(
            canDoubleClick("com.microsoft.VSCode", ["AXStaticText", "AXRow", "AXOutline", "AXWebArea"]),
            "树形列表的行"
        )
        XCTAssertFalse(
            canDoubleClick("com.apple.mail", ["AXStaticText", "AXCell", "AXRow", "AXTable", "AXScrollArea"]),
            "原生列表与表格的行"
        )
    }

    // MARK: - View model: editing and languages

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

    // MARK: - Screen translation

    func testScreenTranslationRequiresScreenRecordingPermission() async {
        let untrusted = makeTranslatorViewModel()
        let trusted = makeTranslatorViewModel(environment: MemoryTranslatorEnvironment(isScreenCaptureTrusted: true))

        guard case .notice? = await untrusted.beginScreenTranslation() else {
            return XCTFail("未获屏幕录制权限时只弹出提示")
        }
        XCTAssertNil(untrusted.session)
        XCTAssertEqual(untrusted.notice, .screenRecordingRequired)

        guard case .selection? = await trusted.beginScreenTranslation() else {
            return XCTFail("已获屏幕录制权限时定格画面进入框选")
        }
        XCTAssertNil(trusted.session)
        XCTAssertNil(trusted.notice)
    }

    func testFailedScreenFreezeShowsNotice() async {
        let viewModel = makeTranslatorViewModel(
            screenRecognizer: RecordingScreenTextRecognizer(error: StubError(message: "授权后尚未重新打开")),
            environment: MemoryTranslatorEnvironment(isScreenCaptureTrusted: true)
        )

        guard case .notice? = await viewModel.beginScreenTranslation() else {
            return XCTFail("截屏失败时只弹出提示")
        }
        XCTAssertNil(viewModel.session)
        XCTAssertEqual(viewModel.notice, .screenCaptureFailed)
    }

    func testScreenRegionIsRecognizedThenTranslatedBesideSelection() async throws {
        let rect = CGRect(x: 100, y: 200, width: 300, height: 80)
        let recognizer = RecordingScreenTextRecognizer { _ in "Hello" }
        let viewModel = makeTranslatorViewModel(screenRecognizer: recognizer)

        let presentation = viewModel.translateScreenRegion(rect, in: Self.snapshot)

        XCTAssertEqual(presentation, TranslatorPresentation(anchorRect: rect))
        XCTAssertEqual(viewModel.session?.state, .recognizing, "识别期间气泡先弹出")
        XCTAssertEqual(viewModel.session?.source, .screen)
        try await waitUntil { viewModel.session?.state == .finished }
        XCTAssertEqual(recognizer.rects, [rect])
        XCTAssertEqual(viewModel.session?.sourceText, "Hello")
        XCTAssertEqual(viewModel.session?.source, .screen)
        XCTAssertEqual(viewModel.translationToCopy, "你好")
        XCTAssertNil(viewModel.notice)
    }

    func testScreenRegionWithoutTextOrFailedCaptureShowsNotice() async throws {
        let rect = CGRect(x: 0, y: 0, width: 200, height: 40)
        let empty = makeTranslatorViewModel(screenRecognizer: RecordingScreenTextRecognizer())
        let failing = makeTranslatorViewModel(
            screenRecognizer: RecordingScreenTextRecognizer(error: StubError(message: "未获授权"))
        )

        _ = empty.translateScreenRegion(rect, in: Self.snapshot)
        _ = failing.translateScreenRegion(rect, in: Self.snapshot)
        try await waitUntil { empty.notice != nil && failing.notice != nil }

        XCTAssertNil(empty.session)
        XCTAssertEqual(empty.notice, .noTextInSelection)
        XCTAssertNil(failing.session)
        XCTAssertEqual(failing.notice, .screenCaptureFailed)
    }

    /// 重新框选取代进行中的识别：旧选区的结果到达后被丢弃。
    func testNewSelectionSupersedesPendingRecognition() async throws {
        let first = CGRect(x: 0, y: 0, width: 200, height: 40)
        let second = CGRect(x: 0, y: 300, width: 200, height: 40)
        let recognizer = RecordingScreenTextRecognizer { rect in rect.minY == 0 ? "first" : "second" }
        let viewModel = makeTranslatorViewModel(screenRecognizer: recognizer)

        _ = viewModel.translateScreenRegion(first, in: Self.snapshot)
        let presentation = viewModel.translateScreenRegion(second, in: Self.snapshot)
        try await waitUntil { viewModel.session?.state == .finished }

        XCTAssertEqual(presentation, TranslatorPresentation(anchorRect: second))
        XCTAssertEqual(viewModel.session?.sourceText, "second")
    }

    /// 气泡收起时取消识别：识别没有响应取消、照常返回文字时结果也被丢弃，不再发出翻译请求，淡出途中气泡内容不变。
    func testCancelledRecognitionDoesNotStartTranslation() async throws {
        let answerer = RecordingAnswerer(deltas: ["你好"])
        let recognizer = RecordingScreenTextRecognizer { _ in "Hello" }
        let viewModel = makeTranslatorViewModel(screenRecognizer: recognizer, answerer: answerer)

        _ = viewModel.translateScreenRegion(CGRect(x: 0, y: 0, width: 200, height: 40), in: Self.snapshot)
        viewModel.cancelRecognition()
        try await waitUntil { recognizer.rects.count == 1 }
        try await Task.sleep(for: .milliseconds(20))

        XCTAssertEqual(viewModel.session?.state, .recognizing)
        XCTAssertNil(viewModel.notice)
        XCTAssertEqual(answerer.recorder.questions, [])
    }

    /// 识别期间在气泡中切换的目标语言，识别完成后仍然沿用。
    func testTargetLanguageChosenWhileRecognizingIsKept() async throws {
        let viewModel = makeTranslatorViewModel(screenRecognizer: RecordingScreenTextRecognizer { _ in "Hello" })

        _ = viewModel.translateScreenRegion(CGRect(x: 0, y: 0, width: 200, height: 40), in: Self.snapshot)
        viewModel.selectTargetLanguage(.japanese)
        try await waitUntil { viewModel.session?.state == .finished }

        XCTAssertEqual(viewModel.session?.sourceText, "Hello")
        XCTAssertEqual(viewModel.session?.targetLanguage, .japanese)
        XCTAssertEqual(viewModel.session?.isTargetLanguagePinned, true)
    }

    func testParagraphsJoinWrappedEnglishLines() {
        let text = VisionScreenTextRecognizer.paragraphs(from: [
            line("The quick brown fox jumps over", y: 0, width: 300),
            line("the lazy dog.", y: 26, width: 130),
        ])

        XCTAssertEqual(text, "The quick brown fox jumps over the lazy dog.")
    }

    func testParagraphsRestoreHyphenatedWordsAndJoinChineseWithoutSpaces() {
        let english = VisionScreenTextRecognizer.paragraphs(from: [
            line("This is an extraordi-", y: 0, width: 210),
            line("nary example.", y: 26, width: 130),
        ])
        let chinese = VisionScreenTextRecognizer.paragraphs(from: [
            line("截图中的文字按版面折行，", y: 0, width: 240),
            line("翻译前要接回一行。", y: 26, width: 180),
        ])

        XCTAssertEqual(english, "This is an extraordinary example.")
        XCTAssertEqual(chinese, "截图中的文字按版面折行，翻译前要接回一行。")
    }

    /// 标题、段落末行等没写到行尾的行，以及段落间距之后的行，都保留换行。
    func testParagraphsKeepBreaksAfterShortLinesAndParagraphGaps() {
        let text = VisionScreenTextRecognizer.paragraphs(from: [
            line("Settings", y: 0, width: 80),
            line("Turn on notifications to receive", y: 30, width: 320),
            line("updates.", y: 56, width: 80),
            line("Next paragraph starts here.", y: 110, width: 270),
            line("   ", y: 140, width: 30),
        ])

        XCTAssertEqual(text, "Settings\nTurn on notifications to receive updates.\nNext paragraph starts here.")
        XCTAssertEqual(VisionScreenTextRecognizer.paragraphs(from: []), "")
    }

    /// 不在上一行下方的行（换栏、并排的文字）不接在上一行之后。
    func testParagraphsDoNotJoinLinesBesideOrAbovePreviousLine() {
        let text = VisionScreenTextRecognizer.paragraphs(from: [
            line("Left column fills its width", y: 100, width: 270),
            line("right column", x: 400, y: 0, width: 120),
        ])

        XCTAssertEqual(text, "Left column fills its width\nright column")
    }

    func testSelectionRectNormalizesDragDirectionAndStaysOnScreen() {
        let bounds = NSRect(x: 0, y: 0, width: 1440, height: 900)

        XCTAssertEqual(
            ScreenSelectionOverlay.selectionRect(from: NSPoint(x: 300, y: 400), to: NSPoint(x: 100, y: 250), within: bounds),
            NSRect(x: 100, y: 250, width: 200, height: 150)
        )
        XCTAssertEqual(
            ScreenSelectionOverlay.selectionRect(from: NSPoint(x: 1400, y: 50), to: NSPoint(x: 1600, y: -20), within: bounds),
            NSRect(x: 1400, y: 0, width: 40, height: 50),
            "拖出屏幕时选区停在屏幕边缘"
        )
    }

    func testAppKitCoordinatesConvertBackToGlobal() {
        let global = CGRect(x: 100, y: 200, width: 80, height: 18)
        let appKit = TranslatorPlacement.appKitRect(fromGlobal: global, primaryScreenHeight: 900)

        XCTAssertEqual(TranslatorPlacement.globalRect(fromAppKit: appKit, primaryScreenHeight: 900), global)
    }

    // MARK: - Speech

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

    // MARK: - Placement

    func testPlacementPrefersBelowAnchorAndGrowsDownward() {
        let placement = TranslatorPlacement(
            anchor: NSRect(x: 200, y: 600, width: 80, height: 18),
            pointer: NSPoint(x: 220, y: 609),
            visibleFrame: Self.visibleFrame,
            width: 380,
            expectedHeight: 420
        )

        XCTAssertEqual(placement.edge, .below(top: 594))
        XCTAssertEqual(placement.frame(height: 150), NSRect(x: 200, y: 444, width: 380, height: 150))
        XCTAssertEqual(placement.frame(height: 300), NSRect(x: 200, y: 294, width: 380, height: 300))
    }

    func testPlacementFlipsAboveNearScreenBottomAndGrowsUpward() {
        let placement = TranslatorPlacement(
            anchor: NSRect(x: 200, y: 100, width: 80, height: 18),
            pointer: NSPoint(x: 220, y: 109),
            visibleFrame: Self.visibleFrame,
            width: 380,
            expectedHeight: 420
        )

        XCTAssertEqual(placement.edge, .above(bottom: 124))
        XCTAssertEqual(placement.frame(height: 150), NSRect(x: 200, y: 124, width: 380, height: 150))
        XCTAssertEqual(placement.frame(height: 300), NSRect(x: 200, y: 124, width: 380, height: 300))
    }

    func testPlacementStaysInsideScreenHorizontally() {
        let placement = TranslatorPlacement(
            anchor: NSRect(x: 1400, y: 600, width: 30, height: 18),
            pointer: NSPoint(x: 1410, y: 609),
            visibleFrame: Self.visibleFrame,
            width: 380,
            expectedHeight: 420
        )

        XCTAssertEqual(placement.x, 1440 - 8 - 380)
    }

    /// 跨大半屏的长选区上下都放不下时，改为贴着指针弹出，而不是压在选区中间。
    func testTallAnchorFallsBackToPointer() {
        let placement = TranslatorPlacement(
            anchor: NSRect(x: 100, y: 50, width: 600, height: 800),
            pointer: NSPoint(x: 300, y: 500),
            visibleFrame: Self.visibleFrame,
            width: 380,
            expectedHeight: 420
        )

        XCTAssertEqual(placement.edge, .below(top: 484))
        XCTAssertEqual(placement.x, 276)
    }

    /// 拖动过的气泡左上角留在放下的位置，译文增长时向下伸长，到屏幕底部后整体上移、不超出屏幕。
    func testDetachedPlacementKeepsTopLeftAndGrowsDownward() {
        let placement = TranslatorPlacement(
            keepingTopLeftOf: NSRect(x: 900, y: 500, width: 380, height: 120),
            visibleFrame: Self.visibleFrame
        )

        XCTAssertEqual(placement.frame(height: 120), NSRect(x: 900, y: 500, width: 380, height: 120))
        XCTAssertEqual(placement.frame(height: 300), NSRect(x: 900, y: 320, width: 380, height: 300))
        XCTAssertEqual(placement.frame(height: 700), NSRect(x: 900, y: 8, width: 380, height: 700))
    }

    func testGlobalCoordinatesConvertToAppKit() {
        XCTAssertEqual(
            TranslatorPlacement.appKitRect(fromGlobal: CGRect(x: 10, y: 100, width: 50, height: 20), primaryScreenHeight: 900),
            NSRect(x: 10, y: 780, width: 50, height: 20)
        )
        XCTAssertEqual(
            TranslatorPlacement.appKitPoint(fromGlobal: CGPoint(x: 10, y: 100), primaryScreenHeight: 900),
            NSPoint(x: 10, y: 800)
        )
    }

    // MARK: - Settings

    func testUserDefaultsStoreRoundTripsTranslatorSettings() throws {
        let suiteName = "OITests-Translator-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = AppSettings(
            isForceTouchTranslationEnabled: false,
            translatorShortcut: LauncherShortcut(keyCode: 17, modifiers: 1 << 8 | 1 << 11),
            screenTranslatorShortcut: LauncherShortcut(keyCode: 1, modifiers: 1 << 11 | 1 << 12),
            translationTargetLanguage: .japanese,
            translationAlternateLanguage: .french,
            translationBaseURL: "http://localhost:11434/v1",
            translationModel: "qwen2.5",
            translationReasoningEffort: "low"
        )

        UserDefaultsAppSettingsStore(defaults: defaults).save(settings)

        XCTAssertEqual(UserDefaultsAppSettingsStore(defaults: defaults).load(), settings)
    }

    func testUserDefaultsStoreFallsBackForUnknownLanguageAndInvalidShortcut() throws {
        let suiteName = "OITests-Translator-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("xx", forKey: "settings.translator.targetLanguage")
        defaults.set(2, forKey: "settings.translator.shortcut.keyCode")
        defaults.set(0, forKey: "settings.translator.shortcut.modifiers")
        defaults.set(2, forKey: "settings.translator.screenShortcut.keyCode")
        defaults.set(1 << 9, forKey: "settings.translator.screenShortcut.modifiers")

        let settings = UserDefaultsAppSettingsStore(defaults: defaults).load()

        XCTAssertEqual(settings.translationTargetLanguage, .simplifiedChinese)
        XCTAssertEqual(settings.translatorShortcut, .standardTranslator)
        XCTAssertEqual(settings.screenTranslatorShortcut, .standardScreenTranslator, "只有 ⇧ 不能用作全局快捷键")
    }

    func testApplyTranslatorShortcutActivatesAndPersists() {
        let settingsStore = MemoryAppSettingsStore()
        let viewModel = makeSettingsViewModel(settingsStore: settingsStore)
        let activator = RecordingActivator()
        viewModel.translatorShortcutActivator = activator.activate
        let shortcut = LauncherShortcut(keyCode: 17, modifiers: 1 << 8 | 1 << 11)

        viewModel.applyTranslatorShortcut(shortcut)

        XCTAssertEqual(activator.attempts, [shortcut])
        XCTAssertEqual(settingsStore.load().translatorShortcut, shortcut)
        XCTAssertNil(viewModel.translatorShortcutNotice)
    }

    func testApplyTranslatorShortcutFailureRollsBack() {
        let viewModel = makeSettingsViewModel()
        let activator = RecordingActivator()
        let rejected = LauncherShortcut(keyCode: 17, modifiers: 1 << 8 | 1 << 12)
        activator.errors[rejected] = "该快捷键已被其他应用占用"
        viewModel.translatorShortcutActivator = activator.activate

        viewModel.applyTranslatorShortcut(rejected)

        XCTAssertEqual(activator.attempts, [rejected, .standardTranslator])
        XCTAssertEqual(viewModel.settings.translatorShortcut, .standardTranslator)
        XCTAssertEqual(viewModel.translatorShortcutNotice, .failure("该快捷键已被其他应用占用"))
        XCTAssertNil(viewModel.launcherShortcutNotice, "失败提示只出现在翻译快捷键下")
    }

    func testShortcutsCannotShareTheSameCombination() {
        let viewModel = makeSettingsViewModel()
        let launcherActivator = RecordingActivator()
        let translatorActivator = RecordingActivator()
        viewModel.launcherShortcutActivator = launcherActivator.activate
        viewModel.translatorShortcutActivator = translatorActivator.activate

        let screenActivator = RecordingActivator()
        viewModel.screenTranslatorShortcutActivator = screenActivator.activate

        viewModel.applyTranslatorShortcut(.standard)
        viewModel.applyLauncherShortcut(.standardTranslator)
        viewModel.applyScreenTranslatorShortcut(.standardTranslator)
        viewModel.applyTranslatorShortcut(.standardScreenTranslator)

        XCTAssertEqual(translatorActivator.attempts, [])
        XCTAssertEqual(launcherActivator.attempts, [])
        XCTAssertEqual(screenActivator.attempts, [])
        XCTAssertEqual(viewModel.translatorShortcutNotice, .failure("与截图翻译快捷键相同，请换一个组合"))
        XCTAssertEqual(viewModel.launcherShortcutNotice, .failure("与翻译快捷键相同，请换一个组合"))
        XCTAssertEqual(viewModel.screenTranslatorShortcutNotice, .failure("与翻译快捷键相同，请换一个组合"))
        XCTAssertEqual(viewModel.settings.translatorShortcut, .standardTranslator)
        XCTAssertEqual(viewModel.settings.launcherShortcut, .standard)
        XCTAssertEqual(viewModel.settings.screenTranslatorShortcut, .standardScreenTranslator)
    }

    func testApplyScreenTranslatorShortcutActivatesAndPersists() {
        let settingsStore = MemoryAppSettingsStore()
        let viewModel = makeSettingsViewModel(settingsStore: settingsStore)
        let activator = RecordingActivator()
        viewModel.screenTranslatorShortcutActivator = activator.activate
        let shortcut = LauncherShortcut(keyCode: 1, modifiers: 1 << 11 | 1 << 12)

        viewModel.applyScreenTranslatorShortcut(shortcut)

        XCTAssertEqual(activator.attempts, [shortcut])
        XCTAssertEqual(settingsStore.load().screenTranslatorShortcut, shortcut)
        XCTAssertNil(viewModel.screenTranslatorShortcutNotice)

        viewModel.reportScreenTranslatorShortcutRegistrationFailure(StubError(message: "该快捷键已被其他应用占用"))

        XCTAssertEqual(viewModel.screenTranslatorShortcutNotice, .failure("该快捷键已被其他应用占用"))
        XCTAssertNil(viewModel.translatorShortcutNotice)
    }

    /// 两个翻译语言不会相同：选成另一项的语言时两者互换，否则只改这一项。
    func testTranslationLanguagesSwapInsteadOfBecomingTheSame() {
        let settingsStore = MemoryAppSettingsStore()
        let viewModel = makeSettingsViewModel(settingsStore: settingsStore)

        viewModel.setTranslationTargetLanguage(.english)
        XCTAssertEqual(viewModel.settings.translationTargetLanguage, .english)
        XCTAssertEqual(viewModel.settings.translationAlternateLanguage, .simplifiedChinese)

        viewModel.setTranslationAlternateLanguage(.english)
        XCTAssertEqual(viewModel.settings.translationTargetLanguage, .simplifiedChinese)
        XCTAssertEqual(viewModel.settings.translationAlternateLanguage, .english)

        viewModel.setTranslationTargetLanguage(.japanese)
        XCTAssertEqual(viewModel.settings.translationTargetLanguage, .japanese)
        XCTAssertEqual(viewModel.settings.translationAlternateLanguage, .english, "不冲突时只改这一项")
        XCTAssertEqual(settingsStore.load().translationTargetLanguage, .japanese)
        XCTAssertEqual(settingsStore.load().translationAlternateLanguage, .english)
    }

    func testSettingsViewModelRefreshesPermissionsAndForwardsRequests() {
        let environment = MemoryTranslatorEnvironment(isAccessibilityTrusted: false)
        let viewModel = makeSettingsViewModel(environment: environment)
        XCTAssertFalse(viewModel.isAccessibilityTrusted)
        XCTAssertFalse(viewModel.isScreenCaptureTrusted)

        environment.isAccessibilityTrusted = true
        environment.isScreenCaptureTrusted = true
        viewModel.refreshPermissionStatus()
        viewModel.requestAccessibilityAccess()
        viewModel.requestScreenCaptureAccess()
        viewModel.openTrackpadSettings()

        XCTAssertTrue(viewModel.isAccessibilityTrusted)
        XCTAssertTrue(viewModel.isScreenCaptureTrusted)
        XCTAssertEqual(environment.accessibilityRequestCount, 1)
        XCTAssertEqual(environment.screenCaptureRequestCount, 1)
        XCTAssertEqual(environment.trackpadSettingsOpenCount, 1)
    }

    func testReportTranslatorShortcutRegistrationFailureSetsNotice() {
        let viewModel = makeSettingsViewModel()

        viewModel.reportTranslatorShortcutRegistrationFailure(StubError(message: "该快捷键已被其他应用占用"))

        XCTAssertEqual(viewModel.translatorShortcutNotice, .failure("该快捷键已被其他应用占用"))
        XCTAssertNil(viewModel.launcherShortcutNotice)
    }

    // MARK: - Coordinator

    func testCoordinatorRegistersTranslatorShortcutAndForceTouchMonitor() {
        let settingsStore = MemoryAppSettingsStore()
        let launcherService = RecordingShortcutService()
        let translatorService = RecordingShortcutService()
        let screenService = RecordingShortcutService()
        let monitor = RecordingForceTouchMonitor()
        let coordinator = AppCoordinator(
            dependencies: AppDependencies(
                launcherViewModel: makeViewModel(with: [], settingsStore: settingsStore),
                settingsViewModel: makeSettingsViewModel(settingsStore: settingsStore),
                settingsStore: settingsStore,
                applicationIconProvider: StubIconProvider(),
                globalShortcutService: launcherService,
                translator: TranslatorDependencies(
                    makeViewModel: { self.makeTranslatorViewModel(settings: AppSettings()) },
                    shortcutService: translatorService,
                    screenShortcutService: screenService,
                    forceTouchMonitor: monitor
                )
            )
        )
        defer { coordinator.stop() }

        coordinator.start()

        XCTAssertEqual(launcherService.registeredShortcuts, [.standard])
        XCTAssertEqual(translatorService.registeredShortcuts, [.standardTranslator])
        XCTAssertNotNil(translatorService.handler)
        XCTAssertEqual(screenService.registeredShortcuts, [.standardScreenTranslator])
        XCTAssertNotNil(screenService.handler)
        XCTAssertTrue(monitor.isRunning)

        coordinator.stop()

        XCTAssertNil(translatorService.handler)
        XCTAssertNil(screenService.handler)
        XCTAssertFalse(monitor.isRunning)
    }

    /// 用力点按取词关闭时不启动全局监听；在设置中开启或关闭后随之启停。
    func testCoordinatorStartsForceTouchMonitorOnlyWhenEnabled() {
        let settingsStore = MemoryAppSettingsStore(initial: AppSettings(isForceTouchTranslationEnabled: false))
        let settingsViewModel = makeSettingsViewModel(settingsStore: settingsStore)
        let monitor = RecordingForceTouchMonitor()
        let coordinator = AppCoordinator(
            dependencies: AppDependencies(
                launcherViewModel: makeViewModel(with: [], settingsStore: settingsStore),
                settingsViewModel: settingsViewModel,
                settingsStore: settingsStore,
                applicationIconProvider: StubIconProvider(),
                globalShortcutService: RecordingShortcutService(),
                translator: TranslatorDependencies(
                    makeViewModel: { self.makeTranslatorViewModel(settings: AppSettings()) },
                    shortcutService: RecordingShortcutService(),
                    screenShortcutService: RecordingShortcutService(),
                    forceTouchMonitor: monitor
                )
            )
        )
        defer { coordinator.stop() }

        coordinator.start()
        XCTAssertFalse(monitor.isRunning)

        settingsViewModel.settings.isForceTouchTranslationEnabled = true
        XCTAssertTrue(monitor.isRunning)

        settingsViewModel.settings.isForceTouchTranslationEnabled = false
        XCTAssertFalse(monitor.isRunning)
    }

    // MARK: - Helpers

    private static let visibleFrame = NSRect(x: 0, y: 0, width: 1440, height: 875)

    private func makeUseCase(
        answerer: any QuickAIAnswering = RecordingAnswerer(deltas: []),
        detector: StubLanguageDetector = StubLanguageDetector(code: "en"),
        settings: AppSettings = TranslatorTests.configuredSettings
    ) -> TranslateText {
        TranslateText(
            answerer: answerer,
            languageDetector: detector,
            settingsStore: MemoryAppSettingsStore(initial: settings),
            keyStore: MemoryQuickAIKeyStore()
        )
    }

    private func makeTranslatorViewModel(
        capturer: StubTextCapturer = StubTextCapturer(),
        wordSelector: RecordingWordSelector = RecordingWordSelector(),
        screenRecognizer: RecordingScreenTextRecognizer = RecordingScreenTextRecognizer(),
        answerer: any QuickAIAnswering = RecordingAnswerer(deltas: ["你好"]),
        detector: StubLanguageDetector = StubLanguageDetector(code: "en"),
        environment: MemoryTranslatorEnvironment? = nil,
        settings: AppSettings = TranslatorTests.configuredSettings,
        speaker: RecordingTextSpeaker = RecordingTextSpeaker()
    ) -> TranslatorViewModel {
        let settingsStore = MemoryAppSettingsStore(initial: settings)
        return TranslatorViewModel(
            translateText: TranslateText(
                answerer: answerer,
                languageDetector: detector,
                settingsStore: settingsStore,
                keyStore: MemoryQuickAIKeyStore()
            ),
            textCapturer: capturer,
            wordSelector: wordSelector,
            screenTextRecognizer: screenRecognizer,
            environment: environment ?? MemoryTranslatorEnvironment(isAccessibilityTrusted: true),
            settingsStore: settingsStore,
            speaker: speaker
        )
    }

    private func makeSettingsViewModel(
        settingsStore: any AppSettingsStoring = MemoryAppSettingsStore(),
        environment: MemoryTranslatorEnvironment? = nil
    ) -> SettingsViewModel {
        SettingsViewModel(
            settingsStore: settingsStore,
            loginItemController: StubLoginItemController(),
            translatorEnvironment: environment ?? MemoryTranslatorEnvironment()
        )
    }

    /// 截图中识别出的一行，`frame` 为像素坐标（原点在左上角）。
    private func line(
        _ text: String,
        x: CGFloat = 0,
        y: CGFloat,
        width: CGFloat,
        height: CGFloat = 20
    ) -> VisionScreenTextRecognizer.Line {
        VisionScreenTextRecognizer.Line(text: text, frame: CGRect(x: x, y: y, width: width, height: height))
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

private struct StubLanguageDetector: LanguageDetecting {
    private let codes: [String: String]
    private let fallback: String?

    init(code: String?) {
        codes = [:]
        fallback = code
    }

    init(codes: [String: String]) {
        self.codes = codes
        fallback = nil
    }

    func dominantLanguageCode(of text: String) -> String? {
        codes[text] ?? fallback
    }
}

private struct StubTextCapturer: TextCapturing {
    var selection: CapturedText?
    var wordAtPoint: CapturedText?
    /// The lookup result when there is no word at the point.
    var lookupWithoutWord: WordLookup = .notOnText
    var clipboard: CapturedText?

    func selectedText() async -> CapturedText? {
        selection
    }

    func word(at point: CGPoint) async -> WordLookup {
        wordAtPoint.map(WordLookup.found) ?? lookupWithoutWord
    }

    @MainActor
    func clipboardText() -> CapturedText? {
        clipboard
    }
}

/// Returns the given word and records the points it was asked to select at.
private final class RecordingWordSelector: WordSelecting, @unchecked Sendable {
    private let lock = NSLock()
    private let selected: CapturedText?
    private var storedPoints: [CGPoint] = []

    init(selected: CapturedText? = nil) {
        self.selected = selected
    }

    var points: [CGPoint] {
        lock.withLock { storedPoints }
    }

    func selectWord(at point: CGPoint) async -> CapturedText? {
        lock.withLock { storedPoints.append(point) }
        return selected
    }
}

/// Returns text for each region (or fails capture and recognition with `error`) and records the regions it was asked to recognize.
private final class RecordingScreenTextRecognizer: ScreenTextRecognizing, @unchecked Sendable {
    private let lock = NSLock()
    private let error: StubError?
    private let text: @Sendable (CGRect) -> String
    private var storedRects: [CGRect] = []

    init(error: StubError? = nil, text: @escaping @Sendable (CGRect) -> String = { _ in "" }) {
        self.error = error
        self.text = text
    }

    var rects: [CGRect] {
        lock.withLock { storedRects }
    }

    func captureScreens() async throws -> ScreenSnapshot {
        if let error {
            throw error
        }
        return ScreenSnapshot(displays: [])
    }

    func recognizeText(in rect: CGRect, of snapshot: ScreenSnapshot) async throws -> String {
        lock.withLock { storedRects.append(rect) }
        if let error {
            throw error
        }
        return text(rect)
    }
}

/// Records the questions, system prompts and endpoint configurations the answerer was asked with.
private final class TranslationRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedQuestions: [String] = []
    private var storedPrompts: [String] = []
    private var storedConfigurations: [QuickAIConfiguration] = []

    var questions: [String] {
        lock.withLock { storedQuestions }
    }

    var prompts: [String] {
        lock.withLock { storedPrompts }
    }

    var configurations: [QuickAIConfiguration] {
        lock.withLock { storedConfigurations }
    }

    func record(question: String, prompt: String, configuration: QuickAIConfiguration) {
        lock.withLock {
            storedQuestions.append(question)
            storedPrompts.append(prompt)
            storedConfigurations.append(configuration)
        }
    }
}

/// Yields the given deltas, then finishes (or fails with `error`).
private struct RecordingAnswerer: QuickAIAnswering {
    let deltas: [String]
    let error: QuickAIClientError?
    let recorder = TranslationRequestRecorder()

    init(deltas: [String], error: QuickAIClientError? = nil) {
        self.deltas = deltas
        self.error = error
    }

    func streamAnswer(
        to question: String,
        systemPrompt: String,
        configuration: QuickAIConfiguration
    ) -> AsyncThrowingStream<String, Error> {
        recorder.record(question: question, prompt: systemPrompt, configuration: configuration)
        return AsyncThrowingStream { continuation in
            for delta in deltas {
                continuation.yield(delta)
            }
            continuation.finish(throwing: error)
        }
    }
}

/// Records what it was asked to speak; each speech lasts until `finishSpeaking()` or until its task is cancelled.
@MainActor
private final class RecordingTextSpeaker: TextSpeaking {
    struct Request: Equatable {
        let text: String
        let languageCode: String?
    }

    private(set) var requests: [Request] = []
    private(set) var cancelledCount = 0
    private var continuation: CheckedContinuation<Void, Never>?

    func speak(_ text: String, languageCode: String?) async {
        requests.append(Request(text: text, languageCode: languageCode))
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation = $0 }
        } onCancel: {
            Task { @MainActor in self.cancel() }
        }
    }

    func finishSpeaking() {
        continuation?.resume()
        continuation = nil
    }

    private func cancel() {
        guard continuation != nil else { return }
        cancelledCount += 1
        finishSpeaking()
    }
}

/// Yields one delta and never finishes: a translation still being generated.
/// Continuations are retained so the stream only ends when the consumer cancels.
private final class HangingAnswerer: QuickAIAnswering, @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [AsyncThrowingStream<String, Error>.Continuation] = []

    func streamAnswer(
        to question: String,
        systemPrompt: String,
        configuration: QuickAIConfiguration
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            lock.withLock { continuations.append(continuation) }
            continuation.yield("部分")
        }
    }
}

@MainActor
private final class RecordingActivator {
    private(set) var attempts: [LauncherShortcut] = []
    var errors: [LauncherShortcut: String] = [:]

    func activate(_ shortcut: LauncherShortcut) throws {
        attempts.append(shortcut)
        if let error = errors[shortcut] {
            throw StubError(message: error)
        }
    }
}

@MainActor
private final class RecordingShortcutService: GlobalShortcutHandling {
    private(set) var registeredShortcuts: [LauncherShortcut] = []
    private(set) var handler: (() -> Void)?

    func register(keyCode: UInt32, modifiers: UInt32, handler: @escaping () -> Void) throws {
        registeredShortcuts.append(LauncherShortcut(keyCode: keyCode, modifiers: modifiers))
        self.handler = handler
    }

    func unregister() {
        handler = nil
    }
}

@MainActor
private final class RecordingForceTouchMonitor: ForceTouchMonitoring {
    private(set) var isRunning = false

    func start(handler: @escaping (CGPoint) -> Void) {
        isRunning = true
    }

    func stop() {
        isRunning = false
    }
}

private struct StubError: LocalizedError {
    let message: String

    var errorDescription: String? { message }
}

@MainActor
private final class StubIconProvider: ApplicationIconProviding {
    func icon(for url: URL) -> NSImage { NSImage() }
}

@MainActor
private final class StubLoginItemController: LoginItemControlling {
    var status: LoginItemStatus = .notRegistered

    func register() throws {}
    func unregister() throws {}
}
