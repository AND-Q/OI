import CoreGraphics
import Foundation

@MainActor
final class TranslatorViewModel: ObservableObject {
    /// 流式增量合并上屏的间隔：避免每个 token 都触发一次重新排版。
    static let flushInterval: Duration = .milliseconds(50)

    @Published private(set) var session: TranslatorSession?
    @Published private(set) var notice: TranslatorNotice?

    private let translateText: TranslateText
    private let textCapturer: any TextCapturing
    private let wordSelector: any WordSelecting
    private let environment: any TranslatorEnvironmentHandling
    private let settingsStore: any AppSettingsStoring

    private var translationTask: Task<Void, Never>?
    private lazy var translationBuffer = StreamingTextBuffer(interval: TranslatorViewModel.flushInterval) { [weak self] text in
        self?.session?.translation += text
        self?.session?.isCopied = false
    }
    private var translationGeneration = 0
    private var captureGeneration = 0

    init(
        translateText: TranslateText,
        textCapturer: any TextCapturing,
        wordSelector: any WordSelecting,
        environment: any TranslatorEnvironmentHandling,
        settingsStore: any AppSettingsStoring
    ) {
        self.translateText = translateText
        self.textCapturer = textCapturer
        self.wordSelector = wordSelector
        self.environment = environment
        self.settingsStore = settingsStore
    }

    deinit {
        translationTask?.cancel()
    }

    /// 复制与回车使用的译文；尚无可见译文时为 nil。
    var translationToCopy: String? {
        guard let translation = session?.visibleTranslation, !translation.isEmpty else { return nil }
        return translation
    }

    /// 快捷键触发：优先翻译前台应用中选中的文字，未选中时翻译剪贴板；两者都没有时只展示提示。
    /// 返回气泡的展示位置；被更新的一次触发取代时返回 nil。
    func captureFromShortcut() async -> TranslatorPresentation? {
        let generation = beginCapture()
        let isTrusted = environment.isAccessibilityTrusted
        var selection: CapturedText?
        if isTrusted {
            selection = await textCapturer.selectedText()
        }
        guard generation == captureGeneration else { return nil }

        if let selection {
            start(with: selection, notice: nil)
            return TranslatorPresentation(anchorRect: selection.screenRect)
        }
        if let clipboard = textCapturer.clipboardText() {
            start(with: clipboard, notice: isTrusted ? nil : .clipboardUsedWithoutAccessibility)
            return TranslatorPresentation(anchorRect: nil)
        }
        stopTranslation()
        session = nil
        notice = isTrusted ? .nothingToTranslate : .accessibilityRequired
        return TranslatorPresentation(anchorRect: nil)
    }

    /// 触控板用力点按触发：只翻译该处的单词——先用辅助功能接口取词，应用不提供该处的文字位置时
    /// （如 VS Code、Chrome）再模拟双击选词。选中的文字只由翻译快捷键翻译：很多应用读不到选区位置，
    /// 无从核实是否按在选区上，两种操作分开后各自的结果才确定。
    /// 该处不是文字、功能已关闭或未获辅助功能权限时返回 nil，不弹出气泡，避免在桌面、图片等位置误弹。
    func captureFromForceTouch(at point: CGPoint) async -> TranslatorPresentation? {
        guard settingsStore.load().isForceTouchTranslationEnabled, environment.isAccessibilityTrusted else {
            return nil
        }
        let generation = beginCapture()

        let captured: CapturedText?
        switch await textCapturer.word(at: point) {
        case .found(let word):
            captured = word
        case .notOnText:
            return nil
        case .unavailable:
            // 双击会改动目标应用的选区，已被更新的一次触发取代时不再进行。
            guard generation == captureGeneration else { return nil }
            captured = await wordSelector.selectWord(at: point)
        }
        guard generation == captureGeneration, let captured else { return nil }
        start(with: captured, notice: nil)
        return TranslatorPresentation(anchorRect: captured.screenRect)
    }

    /// 修改原文即丢弃旧译文、回到待翻译状态，按回车以新原文重新翻译。
    func updateSourceText(_ text: String) {
        guard let current = session, text != current.sourceText else { return }
        stopTranslation()
        session?.sourceText = text
        session?.translation = ""
        session?.state = .draft
        session?.isCopied = false
    }

    /// 回车：翻译当前原文（待翻译与重试共用）。原文语言随修改重新识别，未手动选过目标语言时目标随之调整。
    func translateCurrentSource() {
        guard let session else { return }
        let text = session.sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let request = translateText.makeRequest(
            for: text,
            target: session.isTargetLanguagePinned ? session.targetLanguage : nil
        )
        stream(request)
    }

    /// 切换目标语言并立即重新翻译；只对本次翻译生效，默认语言在设置中调整。
    func selectTargetLanguage(_ language: TranslationLanguage) {
        guard session != nil else { return }
        session?.targetLanguage = language
        session?.isTargetLanguagePinned = true
        translateCurrentSource()
    }

    /// 中断进行中的翻译，保留已到达的译文，避免气泡淡出途中内容变化。
    func stopTranslation() {
        guard translationTask != nil else { return }
        translationGeneration += 1
        translationTask?.cancel()
        translationTask = nil
        translationBuffer.flush()
        if session?.isStreaming == true {
            session?.state = .finished
        }
    }

    /// 气泡隐藏后清空会话与提示。
    func reset() {
        stopTranslation()
        translationBuffer.discard()
        session = nil
        notice = nil
    }

    func markCopied() {
        session?.isCopied = true
    }

    func requestAccessibilityAccess() {
        environment.requestAccessibilityAccess()
    }

    private func beginCapture() -> Int {
        captureGeneration += 1
        return captureGeneration
    }

    private func start(with captured: CapturedText, notice: TranslatorNotice?) {
        let request = translateText.makeRequest(for: captured.text)
        self.notice = notice
        session = TranslatorSession(
            sourceText: captured.text,
            source: captured.source,
            sourceLanguageCode: request.sourceLanguageCode,
            targetLanguage: request.targetLanguage
        )
        stream(request)
    }

    private func stream(_ request: TranslationRequest) {
        stopTranslation()
        translationBuffer.discard()
        translationGeneration += 1
        let generation = translationGeneration
        session?.sourceLanguageCode = request.sourceLanguageCode
        session?.targetLanguage = request.targetLanguage
        session?.translation = ""
        session?.state = .streaming
        session?.isCopied = false

        let translateText = self.translateText
        translationTask = Task { [weak self] in
            do {
                try await translateText.execute(request) { delta in
                    guard let self, self.translationGeneration == generation else { return }
                    self.translationBuffer.append(delta)
                }
                guard let self, self.translationGeneration == generation else { return }
                self.translationBuffer.flush()
                self.session?.state = .finished
            } catch {
                // 中断（隐藏气泡、修改原文、切换语言）会递增 generation，取消带来的错误在此丢弃。
                guard let self, self.translationGeneration == generation else { return }
                self.translationBuffer.flush()
                self.session?.state = .failed(TranslatorErrorMessage.message(for: error))
            }

            if let self, self.translationGeneration == generation {
                self.translationTask = nil
            }
        }
    }
}

private enum TranslatorErrorMessage {
    static func message(for error: Error) -> String {
        switch error as? ApplicationError {
        case .quickAINotConfigured?:
            "划词翻译使用 Quick AI 的接口，请先在「设置… → Quick AI」中填写接口地址与模型。"
        case .quickAIFailed(let reason)?:
            "翻译失败：\(reason)"
        default:
            "翻译失败，请重试。"
        }
    }
}
