import AppKit
import AVFoundation
import Foundation
import XCTest

@testable import OI

/// 截图翻译：定格画面、识别选区文字与整理段落。
@MainActor
final class ScreenTranslationTests: TranslatorTestCase {
    // MARK: - 截图翻译

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
}
