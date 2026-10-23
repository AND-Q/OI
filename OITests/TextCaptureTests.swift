import AppKit
import AVFoundation
import Foundation
import XCTest

@testable import OI

/// 取词：单词边界、待翻译文字的整理与双击选词。
@MainActor
final class TextCaptureTests: TranslatorTestCase {
    // MARK: - 单词边界

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
        XCTAssertNil(CapturedText.cleaned(" \n "))
        XCTAssertEqual(CapturedText.cleaned("  hi \n"), "hi")
        let long = String(repeating: "a", count: CapturedText.maximumLength + 10)
        XCTAssertEqual(CapturedText.cleaned(long)?.count, CapturedText.maximumLength)
    }

    // MARK: - 双击选词

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
}
