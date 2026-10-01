import AppKit
import ApplicationServices
import os

/// 用辅助功能 API 读取其他应用中的文字，用剪贴板兜底。
/// 原生文本控件走字符区间属性（`AXSelectedText`、`AXRangeForPosition` 等）；WebKit 与 Chromium
/// 的网页内容不提供字符区间，改用文本标记（text marker）属性。安全输入框（密码）一律不读取。
struct AccessibilityTextCapturer: TextCapturing {
    /// 单次最多取用的字符数，避免全选长文档时把整篇内容发送出去。
    static let maximumLength = 5000
    /// 对目标进程的辅助功能查询最多等待的秒数，目标应用卡顿时不至于长时间没有反应。
    private static let messagingTimeout: Float = 0.5
    /// 取单词时只读取点按位置两侧这么多字符，足以覆盖一个单词，长文档也不必整篇读取。
    private static let wordWindowRadius = 64
    /// 判定点中单词时，单词区域向外放宽的距离。
    private static let hitTolerance: CGFloat = 3
    /// 网页选区所在的 AXWebArea 可能在焦点元素（如链接）之上，向上查找的最大层数。
    private static let maximumAncestorDepth = 8
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "OI", category: "Translator")

    func selectedText() async -> CapturedText? {
        guard let processID = await MainActor.run(body: { Self.frontmostForeignProcessID() }) else {
            return nil
        }
        return await Task.detached(priority: .userInitiated) {
            Self.readSelection(processID: processID)
        }.value
    }

    func word(at point: CGPoint) async -> CapturedText? {
        let ownProcessID = ProcessInfo.processInfo.processIdentifier
        return await Task.detached(priority: .userInitiated) {
            Self.readWord(at: point, excludingProcessID: ownProcessID)
        }.value
    }

    @MainActor
    func clipboardText() -> CapturedText? {
        let pasteboard = NSPasteboard.general
        // nspasteboard.org 约定：密码管理器复制的敏感内容带此标记，不读取也就不会发送出去。
        let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
        if pasteboard.types?.contains(concealedType) == true { return nil }
        guard let text = pasteboard.string(forType: .string), let cleaned = Self.cleaned(text) else {
            return nil
        }
        return CapturedText(text: cleaned, source: .clipboard, screenRect: nil)
    }

    /// `text` 中包含 `utf16Offset` 的单词区间（UTF-16，与辅助功能 API 的字符区间一致）；
    /// 该位置是空白或标点时为 nil。按系统词边界切分，中文等不以空格分词的语言也能切出词语。
    static func wordRange(in text: String, containing utf16Offset: Int) -> NSRange? {
        let string = text as NSString
        guard utf16Offset >= 0, utf16Offset < string.length else { return nil }
        var match: NSRange?
        string.enumerateSubstrings(
            in: NSRange(location: 0, length: string.length),
            options: [.byWords, .substringNotRequired]
        ) { _, range, _, stop in
            if NSLocationInRange(utf16Offset, range) {
                match = range
                stop.pointee = true
            } else if range.location > utf16Offset {
                stop.pointee = true
            }
        }
        return match
    }

    /// 去掉首尾空白并截断过长的内容；只剩空白时为 nil。
    static func cleaned(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(maximumLength))
    }

    // MARK: - Selection

    @MainActor
    private static func frontmostForeignProcessID() -> pid_t? {
        guard let application = NSWorkspace.shared.frontmostApplication,
              application.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return nil }
        return application.processIdentifier
    }

    private static func readSelection(processID: pid_t) -> CapturedText? {
        let application = AXUIElementCreateApplication(processID)
        AXUIElementSetMessagingTimeout(application, messagingTimeout)
        enableAccessibilityTree(of: application)
        guard let focused = uiElement(attribute(application, kAXFocusedUIElementAttribute)),
              !isSecureTextField(focused) else { return nil }
        AXUIElementSetMessagingTimeout(focused, messagingTimeout)
        return selectionUsingCharacterRange(in: focused) ?? selectionUsingTextMarkers(startingAt: focused)
    }

    private static func selectionUsingCharacterRange(in element: AXUIElement) -> CapturedText? {
        guard let text = attribute(element, kAXSelectedTextAttribute) as? String,
              let cleaned = cleaned(text) else { return nil }
        let characterRangeBounds = range(attribute(element, kAXSelectedTextRangeAttribute))
            .flatMap { axValue(range: $0) }
            .flatMap { rect(attribute(element, kAXBoundsForRangeParameterizedAttribute, parameter: $0)) }
        // WebKit 的网页区域给出选中文字却不支持按字符区间取位置，改用文本标记取位置。
        let bounds = characterRangeBounds ?? attribute(element, "AXSelectedTextMarkerRange")
            .flatMap { rect(attribute(element, "AXBoundsForTextMarkerRange", parameter: $0)) }
        return CapturedText(text: cleaned, source: .selection, screenRect: usable(bounds))
    }

    private static func selectionUsingTextMarkers(startingAt element: AXUIElement) -> CapturedText? {
        var candidate: AXUIElement? = element
        for _ in 0..<maximumAncestorDepth {
            guard let current = candidate else { return nil }
            if let markerRange = attribute(current, "AXSelectedTextMarkerRange"),
               let text = attribute(current, "AXStringForTextMarkerRange", parameter: markerRange) as? String {
                // 找到了提供选区的元素但选区为空：就是没有选中文字。
                guard let cleaned = cleaned(text) else { return nil }
                let bounds = rect(attribute(current, "AXBoundsForTextMarkerRange", parameter: markerRange))
                return CapturedText(text: cleaned, source: .selection, screenRect: usable(bounds))
            }
            candidate = uiElement(attribute(current, kAXParentAttribute))
        }
        return nil
    }

    // MARK: - Word at point

    private static func readWord(at point: CGPoint, excludingProcessID ownProcessID: pid_t) -> CapturedText? {
        let systemWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWide, messagingTimeout)
        var hit: AXUIElement?
        let hitResult = AXUIElementCopyElementAtPosition(systemWide, Float(point.x), Float(point.y), &hit)
        guard hitResult == .success, let hit else {
            logger.debug("No accessibility element under force click (AXError \(hitResult.rawValue, privacy: .public))")
            return nil
        }
        var processID: pid_t = 0
        guard AXUIElementGetPid(hit, &processID) == .success,
              processID != ownProcessID,
              !isSecureTextField(hit) else { return nil }
        enableAccessibilityTree(of: AXUIElementCreateApplication(processID))
        AXUIElementSetMessagingTimeout(hit, messagingTimeout)
        if let word = wordUsingCharacterRange(in: hit, at: point) ?? wordUsingTextMarkers(in: hit, at: point) {
            return word
        }
        let role = attribute(hit, kAXRoleAttribute) as? String ?? "unknown"
        logger.debug("No word under force click in \(role, privacy: .public) of process \(processID, privacy: .public)")
        return nil
    }

    private static func wordUsingCharacterRange(in element: AXUIElement, at point: CGPoint) -> CapturedText? {
        guard let pointValue = axValue(point: point),
              let hitRange = range(attribute(element, kAXRangeForPositionParameterizedAttribute, parameter: pointValue)),
              hitRange.location >= 0 else { return nil }

        guard let window = textWindow(in: element, around: hitRange.location)
                ?? (attribute(element, kAXValueAttribute) as? String).map({ ($0, 0) }) else { return nil }
        let (text, textStart) = window

        guard let match = wordRange(in: text, containing: hitRange.location - textStart) else { return nil }
        let word = (text as NSString).substring(with: match)
        let bounds = axValue(range: CFRange(location: textStart + match.location, length: match.length))
            .flatMap { rect(attribute(element, kAXBoundsForRangeParameterizedAttribute, parameter: $0)) }
        return hitWord(word, bounds: bounds, point: point)
    }

    /// 读取 `location` 两侧的一小段文字及其起始位置。
    private static func textWindow(in element: AXUIElement, around location: Int) -> (String, Int)? {
        let start = max(location - wordWindowRadius, 0)
        var length = location - start + wordWindowRadius
        if let characterCount = attribute(element, kAXNumberOfCharactersAttribute) as? Int {
            length = min(length, characterCount - start)
        }
        guard length > 0,
              let rangeValue = axValue(range: CFRange(location: start, length: length)),
              let text = attribute(element, kAXStringForRangeParameterizedAttribute, parameter: rangeValue) as? String
        else { return nil }
        return (text, start)
    }

    private static func wordUsingTextMarkers(in element: AXUIElement, at point: CGPoint) -> CapturedText? {
        guard let pointValue = axValue(point: point),
              let marker = attribute(element, "AXTextMarkerForPosition", parameter: pointValue) else { return nil }
        // 点在单词中间时右侧单词区间即该单词；点在词尾边界时再看左侧单词。
        for wordAttribute in ["AXRightWordTextMarkerRangeForTextMarker", "AXLeftWordTextMarkerRangeForTextMarker"] {
            guard let markerRange = attribute(element, wordAttribute, parameter: marker),
                  let word = attribute(element, "AXStringForTextMarkerRange", parameter: markerRange) as? String
            else { continue }
            let bounds = rect(attribute(element, "AXBoundsForTextMarkerRange", parameter: markerRange))
            if let captured = hitWord(word, bounds: bounds, point: point) {
                return captured
            }
        }
        return nil
    }

    /// 点在空白处时系统也会返回最近的字符：要求单词区域确实覆盖点按位置，且至少含一个字母或数字。
    private static func hitWord(_ word: String, bounds: CGRect?, point: CGPoint) -> CapturedText? {
        guard let cleaned = cleaned(word),
              cleaned.unicodeScalars.contains(where: CharacterSet.alphanumerics.contains) else { return nil }
        let bounds = usable(bounds)
        if let bounds, !bounds.insetBy(dx: -hitTolerance, dy: -hitTolerance).contains(point) {
            return nil
        }
        return CapturedText(text: cleaned, source: .word, screenRect: bounds)
    }

    // MARK: - Accessibility helpers

    /// Electron 应用默认不构建辅助功能树，按其文档约定由辅助技术开启；其他应用会忽略这个属性。
    private static func enableAccessibilityTree(of application: AXUIElement) {
        AXUIElementSetAttributeValue(application, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    }

    private static func isSecureTextField(_ element: AXUIElement) -> Bool {
        (attribute(element, kAXSubroleAttribute) as? String) == kAXSecureTextFieldSubrole
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    private static func attribute(_ element: AXUIElement, _ name: String, parameter: CFTypeRef) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, name as CFString, parameter, &value) == .success
        else { return nil }
        return value
    }

    private static func uiElement(_ value: CFTypeRef?) -> AXUIElement? {
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private static func range(_ value: CFTypeRef?) -> CFRange? {
        guard let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(value as! AXValue, .cfRange, &range) else { return nil }
        return range
    }

    private static func rect(_ value: CFTypeRef?) -> CGRect? {
        guard let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(value as! AXValue, .cgRect, &rect) else { return nil }
        return rect
    }

    private static func axValue(point: CGPoint) -> AXValue? {
        var point = point
        return AXValueCreate(.cgPoint, &point)
    }

    private static func axValue(range: CFRange) -> AXValue? {
        var range = range
        return AXValueCreate(.cfRange, &range)
    }

    /// 部分应用对取不到位置的文字返回零尺寸或无效区域，按未提供位置处理。
    private static func usable(_ rect: CGRect?) -> CGRect? {
        guard let rect, !rect.isNull, !rect.isInfinite, rect.width > 0 || rect.height > 0 else { return nil }
        return rect
    }
}
