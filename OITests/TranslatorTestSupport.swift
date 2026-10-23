import AppKit
import AVFoundation
import Foundation
import XCTest

@testable import OI

/// 划词翻译各测试共用的基类：测试用的设置、定格画面与创建用例、视图模型的辅助方法。
@MainActor
class TranslatorTestCase: XCTestCase {
    static let configuredSettings = AppSettings(
        translationBaseURL: "https://api.openai.com/v1",
        translationModel: "gpt-4o-mini"
    )
    /// 截图翻译测试用的定格画面：识别由桩按选区返回文字，不读取画面。
    static let snapshot = ScreenSnapshot(displays: [])

    static let visibleFrame = NSRect(x: 0, y: 0, width: 1440, height: 875)

    func makeUseCase(
        answerer: any AIAnswering = RecordingAnswerer(deltas: []),
        detector: StubLanguageDetector = StubLanguageDetector(code: "en"),
        settings: AppSettings = TranslatorTestCase.configuredSettings
    ) -> TranslateText {
        TranslateText(
            answerer: answerer,
            languageDetector: detector,
            settingsStore: MemoryAppSettingsStore(initial: settings),
            keyStore: MemoryAPIKeyStore()
        )
    }

    func makeTranslatorViewModel(
        capturer: StubTextCapturer = StubTextCapturer(),
        wordSelector: RecordingWordSelector = RecordingWordSelector(),
        screenRecognizer: RecordingScreenTextRecognizer = RecordingScreenTextRecognizer(),
        answerer: any AIAnswering = RecordingAnswerer(deltas: ["你好"]),
        detector: StubLanguageDetector = StubLanguageDetector(code: "en"),
        environment: MemoryTranslatorEnvironment? = nil,
        settings: AppSettings = TranslatorTestCase.configuredSettings,
        speaker: RecordingTextSpeaker = RecordingTextSpeaker()
    ) -> TranslatorViewModel {
        let settingsStore = MemoryAppSettingsStore(initial: settings)
        return TranslatorViewModel(
            translateText: TranslateText(
                answerer: answerer,
                languageDetector: detector,
                settingsStore: settingsStore,
                keyStore: MemoryAPIKeyStore()
            ),
            textCapturer: capturer,
            wordSelector: wordSelector,
            screenTextRecognizer: screenRecognizer,
            environment: environment ?? MemoryTranslatorEnvironment(isAccessibilityTrusted: true),
            settingsStore: settingsStore,
            speaker: speaker
        )
    }

    func makeSettingsViewModel(
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
    func line(
        _ text: String,
        x: CGFloat = 0,
        y: CGFloat,
        width: CGFloat,
        height: CGFloat = 20
    ) -> VisionScreenTextRecognizer.Line {
        VisionScreenTextRecognizer.Line(text: text, frame: CGRect(x: x, y: y, width: width, height: height))
    }
}

struct StubLanguageDetector: LanguageDetecting {
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

struct StubTextCapturer: TextCapturing {
    var selection: CapturedText?
    var wordAtPoint: CapturedText?
    /// 点按处没有单词时的取词结果。
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

/// 返回给定的单词，并记录被要求选词的坐标。
final class RecordingWordSelector: WordSelecting, @unchecked Sendable {
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

/// 按选区返回文字（或以 `error` 让截屏与识别失败），并记录被要求识别的选区。
final class RecordingScreenTextRecognizer: ScreenTextRecognizing, @unchecked Sendable {
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

/// 记录问答端口收到的问题、系统提示词与接口配置。
final class TranslationRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedQuestions: [String] = []
    private var storedPrompts: [String] = []
    private var storedConfigurations: [AIEndpointConfiguration] = []

    var questions: [String] {
        lock.withLock { storedQuestions }
    }

    var prompts: [String] {
        lock.withLock { storedPrompts }
    }

    var configurations: [AIEndpointConfiguration] {
        lock.withLock { storedConfigurations }
    }

    func record(question: String, prompt: String, configuration: AIEndpointConfiguration) {
        lock.withLock {
            storedQuestions.append(question)
            storedPrompts.append(prompt)
            storedConfigurations.append(configuration)
        }
    }
}

/// 依次产出给定的增量后结束（或以 `error` 失败）。
struct RecordingAnswerer: AIAnswering {
    let deltas: [String]
    let error: AIClientError?
    let recorder = TranslationRequestRecorder()

    init(deltas: [String], error: AIClientError? = nil) {
        self.deltas = deltas
        self.error = error
    }

    func streamAnswer(
        to question: String,
        systemPrompt: String,
        configuration: AIEndpointConfiguration
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

/// 记录被要求朗读的内容；每段朗读持续到调用 `finishSpeaking()` 或其任务被取消。
@MainActor
final class RecordingTextSpeaker: TextSpeaking {
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

/// 产出一段增量后一直不结束：模拟仍在生成中的译文。保留续体，流只在消费方取消时结束。
final class HangingAnswerer: AIAnswering, @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [AsyncThrowingStream<String, Error>.Continuation] = []

    func streamAnswer(
        to question: String,
        systemPrompt: String,
        configuration: AIEndpointConfiguration
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            lock.withLock { continuations.append(continuation) }
            continuation.yield("部分")
        }
    }
}

@MainActor
final class RecordingActivator {
    private(set) var attempts: [GlobalShortcut] = []
    var errors: [GlobalShortcut: String] = [:]

    func activate(_ shortcut: GlobalShortcut) throws {
        attempts.append(shortcut)
        if let error = errors[shortcut] {
            throw StubError(message: error)
        }
    }
}

@MainActor
final class RecordingShortcutService: GlobalShortcutHandling {
    private(set) var registeredShortcuts: [GlobalShortcut] = []
    private(set) var handler: (() -> Void)?

    func register(keyCode: UInt32, modifiers: UInt32, handler: @escaping () -> Void) throws {
        registeredShortcuts.append(GlobalShortcut(keyCode: keyCode, modifiers: modifiers))
        self.handler = handler
    }

    func unregister() {
        handler = nil
    }
}

@MainActor
final class RecordingForceTouchMonitor: ForceTouchMonitoring {
    private(set) var isRunning = false

    func start(handler: @escaping (CGPoint) -> Void) {
        isRunning = true
    }

    func stop() {
        isRunning = false
    }
}

struct StubError: LocalizedError {
    let message: String

    var errorDescription: String? { message }
}
