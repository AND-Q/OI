import CoreGraphics
import Foundation
import ScreenCaptureKit
import Vision
import os

/// 截图翻译：进入框选时用 ScreenCaptureKit 截下每块屏幕定格画面，框选完成后从中裁出选区，
/// 再用 Vision 在本机识别其中的文字并整理成段落。截图只在内存中识别，不保存也不上传；
/// OI 自身的窗口（框选遮罩、翻译气泡）不入镜，无需先隐藏。
struct VisionScreenTextRecognizer: ScreenTextRecognizing {
    /// 识别出的一行文字与它在截图中的位置（像素，原点在左上角、y 轴向下）。
    struct Line: Equatable {
        let text: String
        let frame: CGRect
    }

    enum CaptureError: LocalizedError {
        case displayNotFound

        var errorDescription: String? {
            String(localized: "找不到选区所在的屏幕")
        }
    }

    /// 识别语种：中文排在最前，中英混排时中文识别更准确；实际语种由 Vision 自动判断。
    private static let recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US", "ja-JP", "ko-KR"]
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "OI", category: "Translator")

    func captureScreens() async throws -> ScreenSnapshot {
        do {
            return try await Self.captureDisplays()
        } catch {
            Self.logger.error("Screen capture failed: \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    func recognizeText(in rect: CGRect, of snapshot: ScreenSnapshot) async throws -> String {
        do {
            let image = try Self.image(in: rect, of: snapshot)
            let lines = try await Self.recognizeLines(in: image)
            return CapturedText.cleaned(Self.paragraphs(from: lines)) ?? ""
        } catch {
            Self.logger.error("Screen text recognition failed: \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    // MARK: - 整理段落

    /// 把逐行识别的文字整理成段落：截图中的文字按版面折行，原样换行会让一句话被当成几句来翻译。
    /// 相邻两行属于同一段时接成一行，否则换行；判断不准时宁可换行，也不把不相干的行拼在一起。
    static func paragraphs(from lines: [Line]) -> String {
        let lines = lines.compactMap { line -> Line? in
            let text = line.text.trimmingCharacters(in: .whitespaces)
            return text.isEmpty ? nil : Line(text: text, frame: line.frame)
        }
        guard let rightEdge = lines.map(\.frame.maxX).max() else { return "" }
        var result = ""
        for (index, line) in lines.enumerated() {
            if index == 0 {
                result = line.text
            } else if continuesParagraph(line, after: lines[index - 1], rightEdge: rightEdge) {
                result = joined(result, line.text)
            } else {
                result += "\n" + line.text
            }
        }
        return result
    }

    /// `line` 是否接续上一行所在的段落：它紧挨在上一行下方，且上一行写到了行尾——行尾的空位放不下
    /// `line` 开头的词，说明是排版折行，而不是一行本就在此结束（标题、列表项、段落末行）。
    /// `rightEdge` 为所有行的最右端，近似正文的右边界。
    static func continuesParagraph(_ line: Line, after previous: Line, rightEdge: CGFloat) -> Bool {
        let lineHeight = max(line.frame.height, previous.frame.height)
        let gap = line.frame.minY - previous.frame.maxY
        // 不在上一行下方（换栏、并排的文字），或行距明显大于正文（空行、段落间距）。
        guard gap > -lineHeight / 2, gap < lineHeight else { return false }
        let characterWidth = line.frame.width / CGFloat(max(line.text.count, 1))
        let leadingWordWidth = CGFloat(leadingWordLength(of: line.text) + 1) * characterWidth
        return rightEdge - previous.frame.maxX < leadingWordWidth
    }

    /// 把下一行接到段落末尾：行尾连字符断开的英文单词去掉连字符直接相连，中日文直接相连，其余用空格连接。
    static func joined(_ text: String, _ next: String) -> String {
        guard let last = text.last, let first = next.first else { return text + next }
        if last == "-", text.dropLast().last?.isLetter == true, first.isLowercase {
            return String(text.dropLast()) + next
        }
        if last.unicodeScalars.contains(where: isCJK) || first.unicodeScalars.contains(where: isCJK) {
            return text + next
        }
        return text + " " + next
    }

    /// 行首的词的字数：中日文按两个字计（避头尾规则可能把行尾的一两个字挤到下一行），其余到第一个空白为止。
    private static func leadingWordLength(of text: String) -> Int {
        guard let first = text.unicodeScalars.first else { return 0 }
        if isCJK(first) { return 2 }
        return text.prefix(while: { !$0.isWhitespace }).count
    }

    /// 中日文字符（汉字、假名、中日文标点与全角字符）：不以空格分词，折行处直接相连。
    private static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3000...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0xFF00...0xFFEF, 0x20000...0x2FFFF:
            true
        default:
            false
        }
    }

    // MARK: - 截屏

    /// 截取每块屏幕的整个画面；按屏幕像素截取，小字号文字也能看清。
    private static func captureDisplays() async throws -> ScreenSnapshot {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let ownProcessID = ProcessInfo.processInfo.processIdentifier
        let ownApplications = content.applications.filter { $0.processID == ownProcessID }
        var displays: [ScreenSnapshot.Display] = []
        for display in content.displays {
            let filter = SCContentFilter(display: display, excludingApplications: ownApplications, exceptingWindows: [])
            let configuration = SCStreamConfiguration()
            let scale = backingScale(of: display.displayID)
            configuration.width = Int((display.frame.width * scale).rounded())
            configuration.height = Int((display.frame.height * scale).rounded())
            configuration.showsCursor = false
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
            displays.append(ScreenSnapshot.Display(displayID: display.displayID, frame: display.frame, image: image))
        }
        return ScreenSnapshot(displays: displays)
    }

    /// 从定格的画面中裁出 `rect`（全局显示坐标）在所在屏幕上的区域。
    private static func image(in rect: CGRect, of snapshot: ScreenSnapshot) throws -> CGImage {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        guard let display = snapshot.displays.first(where: { $0.frame.contains(center) }) else {
            throw CaptureError.displayNotFound
        }
        let region = rect.intersection(display.frame)
        guard !region.isEmpty else { throw CaptureError.displayNotFound }

        // 画面按屏幕像素截取，选区由点换算为像素；CGImage 的裁剪坐标原点在左上角，与全局显示坐标一致。
        let scale = CGFloat(display.image.width) / display.frame.width
        let pixelRect = CGRect(
            x: (region.minX - display.frame.minX) * scale,
            y: (region.minY - display.frame.minY) * scale,
            width: region.width * scale,
            height: region.height * scale
        ).integral
        guard let image = display.image.cropping(to: pixelRect) else { throw CaptureError.displayNotFound }
        return image
    }

    private static func backingScale(of displayID: CGDirectDisplayID) -> CGFloat {
        guard let mode = CGDisplayCopyDisplayMode(displayID), mode.width > 0 else { return 2 }
        return CGFloat(mode.pixelWidth) / CGFloat(mode.width)
    }

    // MARK: - 识别文字

    /// 用新版 `RecognizeTextRequest` 识别：旧版 `VNRecognizeTextRequest` 在 macOS 26 上有崩溃报告。
    private static func recognizeLines(in image: CGImage) async throws -> [Line] {
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = recognitionLanguages.map { Locale.Language(identifier: $0) }
        request.automaticallyDetectsLanguage = true
        request.usesLanguageCorrection = true
        let observations = try await request.perform(on: image)

        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        return observations.compactMap { observation in
            guard let text = observation.topCandidates(1).first?.string else { return nil }
            // Vision 的归一化坐标原点在图像左下角，换算为像素、原点在左上角。
            let box = observation.boundingBox.cgRect
            return Line(
                text: text,
                frame: CGRect(
                    x: box.minX * width,
                    y: (1 - box.maxY) * height,
                    width: box.width * width,
                    height: box.height * height
                )
            )
        }
    }
}
