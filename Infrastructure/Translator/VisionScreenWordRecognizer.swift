import CoreGraphics
import Foundation
import ScreenCaptureKit
import Vision
import os

/// 截图识字：用 ScreenCaptureKit 截取光标周围一小块屏幕，再用 Vision 识别文字，取出光标下的词。
/// 截图只在内存中识别，不保存也不上传；OI 自身的窗口与光标不入镜，避免遮挡文字。
struct VisionScreenWordRecognizer: ScreenWordRecognizing {
    /// 截取区域（点）：横向足以容纳光标所在的一段文字，纵向覆盖上下各一两行。
    private static let captureSize = CGSize(width: 640, height: 120)
    /// 判定光标落在某行文字上的容差。
    private static let lineTolerance: CGFloat = 2
    /// 光标落在两个词之间的空隙时，取不超过此距离的最近的词。
    static let maximumWordGap: CGFloat = 4
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "OI", category: "Translator")

    func word(at point: CGPoint) async -> CapturedText? {
        // 未授权时不发起截屏：截屏会触发系统授权弹窗，授权只在设置中引导。
        guard CGPreflightScreenCaptureAccess() else { return nil }
        do {
            guard let capture = try await Self.captureScreen(around: point) else { return nil }
            let recognized = try Self.recognizeWord(in: capture.image, region: capture.region, at: point)
            if recognized == nil {
                Self.logger.debug("Screen text recognition found no word under force click")
            }
            return recognized
        } catch {
            Self.logger.debug("Screen text recognition failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// 行内横向覆盖 `x` 的词；落在词间空隙时取不超过 `maximumWordGap` 的最近的词。
    static func wordIndex(containing x: CGFloat, in rects: [CGRect]) -> Int? {
        if let index = rects.firstIndex(where: { $0.minX <= x && x <= $0.maxX }) {
            return index
        }
        func distance(_ rect: CGRect) -> CGFloat {
            x < rect.minX ? rect.minX - x : x - rect.maxX
        }
        guard let nearest = rects.indices.min(by: { distance(rects[$0]) < distance(rects[$1]) }),
              distance(rects[nearest]) <= maximumWordGap else { return nil }
        return nearest
    }

    /// Vision 的归一化坐标（原点在图像左下角）转为全局显示坐标（原点在主屏左上角、y 轴向下）。
    static func screenRect(fromNormalized box: CGRect, in region: CGRect) -> CGRect {
        CGRect(
            x: region.minX + box.minX * region.width,
            y: region.minY + (1 - box.maxY) * region.height,
            width: box.width * region.width,
            height: box.height * region.height
        )
    }

    // MARK: - Capture

    /// 截取 `point` 周围的屏幕，返回图像与它对应的屏幕区域（全局显示坐标）。
    private static func captureScreen(around point: CGPoint) async throws -> (image: CGImage, region: CGRect)? {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.frame.contains(point) }) else { return nil }
        let region = CGRect(
            x: point.x - captureSize.width / 2,
            y: point.y - captureSize.height / 2,
            width: captureSize.width,
            height: captureSize.height
        ).intersection(display.frame)
        guard !region.isEmpty else { return nil }

        let ownProcessID = ProcessInfo.processInfo.processIdentifier
        let filter = SCContentFilter(
            display: display,
            excludingApplications: content.applications.filter { $0.processID == ownProcessID },
            exceptingWindows: []
        )
        let configuration = SCStreamConfiguration()
        configuration.sourceRect = region.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
        let scale = backingScale(of: display.displayID)
        configuration.width = Int((region.width * scale).rounded())
        configuration.height = Int((region.height * scale).rounded())
        configuration.showsCursor = false
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        return (image, region)
    }

    /// 按像素截取才能看清小字号文字。
    private static func backingScale(of displayID: CGDirectDisplayID) -> CGFloat {
        guard let mode = CGDisplayCopyDisplayMode(displayID), mode.width > 0 else { return 2 }
        return CGFloat(mode.pixelWidth) / CGFloat(mode.width)
    }

    // MARK: - Recognition

    private static func recognizeWord(in image: CGImage, region: CGRect, at point: CGPoint) throws -> CapturedText? {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        // 保留屏幕上的原样文字：语言纠错会改动代码标识符、专有名词等。
        request.usesLanguageCorrection = false
        request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]
        request.automaticallyDetectsLanguage = true
        try VNImageRequestHandler(cgImage: image).perform([request])

        for observation in request.results ?? [] {
            let lineRect = screenRect(fromNormalized: observation.boundingBox, in: region)
            guard lineRect.insetBy(dx: -lineTolerance, dy: -lineTolerance).contains(point),
                  let candidate = observation.topCandidates(1).first,
                  let captured = word(in: candidate, lineRect: lineRect, region: region, at: point) else { continue }
            return captured
        }
        return nil
    }

    private static func word(
        in candidate: VNRecognizedText,
        lineRect: CGRect,
        region: CGRect,
        at point: CGPoint
    ) -> CapturedText? {
        let text = candidate.string
        let ranges = wordRanges(in: text)
        let length = CGFloat((text as NSString).length)
        guard !ranges.isEmpty, length > 0 else { return nil }

        func estimatedRect(_ range: Range<String.Index>) -> CGRect {
            let utf16Range = NSRange(range, in: text)
            return CGRect(
                x: lineRect.minX + lineRect.width * CGFloat(utf16Range.location) / length,
                y: lineRect.minY,
                width: lineRect.width * CGFloat(utf16Range.length) / length,
                height: lineRect.height
            )
        }
        let measured: [CGRect?] = ranges.map { range in
            (try? candidate.boundingBox(for: range)).map { screenRect(fromNormalized: $0.boundingBox, in: region) }
        }
        // 部分情况下 Vision 只给出整行的位置：各词都接近整行宽时改按字符比例估算。
        let isDegenerate = ranges.count > 1
            && measured.allSatisfy { ($0?.width ?? lineRect.width) >= lineRect.width * 0.9 }
        let wordRects: [CGRect] = zip(ranges, measured).map { range, rect in
            isDegenerate ? estimatedRect(range) : rect ?? estimatedRect(range)
        }

        guard let index = wordIndex(containing: point.x, in: wordRects) else { return nil }
        let recognized = text[ranges[index]].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !recognized.isEmpty, recognized.unicodeScalars.contains(where: CharacterSet.alphanumerics.contains) else {
            return nil
        }
        return CapturedText(text: recognized, source: .word, screenRect: wordRects[index])
    }

    /// 按系统词边界切词，中文等不以空格分词的语言也能切出词语。
    private static func wordRanges(in text: String) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        text.enumerateSubstrings(in: text.startIndex..<text.endIndex, options: [.byWords, .substringNotRequired]) {
            _, range, _, _ in
            ranges.append(range)
        }
        return ranges
    }
}
