import AppKit
import AVFoundation
import Foundation
import XCTest

@testable import OI

/// 划词翻译的目标语言与语种识别。
@MainActor
final class TranslationLanguageTests: TranslatorTestCase {
    // MARK: - 语言

    func testTranslationLanguageMatchesDetectedCodes() {
        XCTAssertEqual(TranslationLanguage(languageCode: "zh-Hant"), .traditionalChinese)
        XCTAssertEqual(TranslationLanguage(languageCode: "zh"), .simplifiedChinese)
        XCTAssertEqual(TranslationLanguage(languageCode: "pt-BR"), .portuguese)
        XCTAssertNil(TranslationLanguage(languageCode: "sw"))
        XCTAssertTrue(TranslationLanguage.simplifiedChinese.isSameLanguage(as: "zh-Hant"), "简繁同属中文")
        XCTAssertFalse(TranslationLanguage.english.isSameLanguage(as: "es"))
    }

    // MARK: - 语种识别

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
            keyStore: MemoryAPIKeyStore()
        )

        let identifier = useCase.makeRequest(for: "reduceKernel")
        let chinese = useCase.makeRequest(for: "归约内核")

        XCTAssertEqual(identifier.sourceLanguageCode, "en")
        XCTAssertEqual(identifier.targetLanguage, .simplifiedChinese)
        XCTAssertEqual(chinese.targetLanguage, .english)
    }
}
