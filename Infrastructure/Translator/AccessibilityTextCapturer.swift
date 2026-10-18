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
    /// 取词时从命中的容器向下查找文字元素的最大层数，以及每层最多检查的子元素数。
    private static let maximumDescendantDepth = 4
    private static let maximumChildrenScanned = 64
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "OI", category: "Translator")

    func selectedText() async -> CapturedText? {
        guard let processID = await MainActor.run(body: { Self.frontmostForeignProcessID() }) else {
            return nil
        }
        return await Task.detached(priority: .userInitiated) {
            Self.readSelection(processID: processID)
        }.value
    }

    func word(at point: CGPoint) async -> WordLookup {
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

    private static func readWord(at point: CGPoint, excludingProcessID ownProcessID: pid_t) -> WordLookup {
        let systemWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWide, messagingTimeout)
        var hit: AXUIElement?
        let hitResult = AXUIElementCopyElementAtPosition(systemWide, Float(point.x), Float(point.y), &hit)
        guard hitResult == .success, let hit else {
            logger.debug("No accessibility element under force click (AXError \(hitResult.rawValue, privacy: .public))")
            return .unavailable
        }
        var processID: pid_t = 0
        guard AXUIElementGetPid(hit, &processID) == .success,
              processID != ownProcessID,
              !isSecureTextField(hit) else { return .notOnText }
        let application = AXUIElementCreateApplication(processID)
        enableAccessibilityTree(of: application)
        AXUIElementSetMessagingTimeout(hit, messagingTimeout)
        var lookup = word(in: hit, at: point)
        if case .found = lookup {
            return lookup
        }
        // 命中的常是不直接提供文字的容器（如 AXGroup）：先找覆盖该点的子元素（由深到浅），
        // 再找祖先元素——网页的文本标记查询由 AXWebArea 等祖先提供。
        let candidates = Array(descendants(of: hit, containing: point).reversed()) + ancestors(of: hit)
        for candidate in candidates {
            guard !isSecureTextField(candidate) else { return .notOnText }
            AXUIElementSetMessagingTimeout(candidate, messagingTimeout)
            lookup = merged(lookup, word(in: candidate, at: point))
            if case .found = lookup {
                return lookup
            }
        }
        let role = attribute(hit, kAXRoleAttribute) as? String ?? "unknown"
        let applicationName = attribute(application, kAXTitleAttribute) as? String ?? "process \(processID)"
        let reason = lookup == .notOnText ? "not on text" : "no text positions"
        var parameterizedNames: CFArray?
        AXUIElementCopyParameterizedAttributeNames(hit, &parameterizedNames)
        let supported = (parameterizedNames as? [String])?.joined(separator: ", ") ?? "none"
        logger.debug(
            "No word under force click (\(reason, privacy: .public)) in \(role, privacy: .public) of \(applicationName, privacy: .public); parameterized attributes: \(supported, privacy: .public)"
        )
        return lookup
    }

    private static func word(in element: AXUIElement, at point: CGPoint) -> WordLookup {
        let lookup = wordUsingCharacterRange(in: element, at: point)
        if case .found = lookup {
            return lookup
        }
        return merged(lookup, wordUsingTextMarkers(in: element, at: point))
    }

    /// 合并两次取词的结果：取到单词优先；其次是能核对位置的「不是文字」，
    /// 只要有一处能核对位置就以它为准；都不能核对时才是无法判断。
    private static func merged(_ first: WordLookup, _ second: WordLookup) -> WordLookup {
        switch (first, second) {
        case (.found, _): first
        case (_, .found): second
        case (.notOnText, _), (_, .notOnText): .notOnText
        default: .unavailable
        }
    }

    /// 从 `element` 逐层向下，每层取第一个覆盖 `point` 的子元素，按由浅到深返回。
    private static func descendants(of element: AXUIElement, containing point: CGPoint) -> [AXUIElement] {
        var chain: [AXUIElement] = []
        var current = element
        for _ in 0..<maximumDescendantDepth {
            guard let children = attribute(current, kAXChildrenAttribute) as? [AXUIElement],
                  let child = children.prefix(maximumChildrenScanned).first(where: {
                      frame(of: $0)?.contains(point) == true
                  }) else { break }
            chain.append(child)
            current = child
        }
        return chain
    }

    private static func ancestors(of element: AXUIElement) -> [AXUIElement] {
        var chain: [AXUIElement] = []
        var current = uiElement(attribute(element, kAXParentAttribute))
        while let ancestor = current, chain.count < maximumAncestorDepth {
            chain.append(ancestor)
            current = uiElement(attribute(ancestor, kAXParentAttribute))
        }
        return chain
    }

    private static func frame(of element: AXUIElement) -> CGRect? {
        var origin = CGPoint.zero
        var size = CGSize.zero
        guard unpack(attribute(element, kAXPositionAttribute), .cgPoint, into: &origin),
              unpack(attribute(element, kAXSizeAttribute), .cgSize, into: &size)
        else { return nil }
        return CGRect(origin: origin, size: size)
    }

    private static func wordUsingCharacterRange(in element: AXUIElement, at point: CGPoint) -> WordLookup {
        guard let pointValue = axValue(point: point),
              let hitRange = range(attribute(element, kAXRangeForPositionParameterizedAttribute, parameter: pointValue)),
              hitRange.location >= 0 else { return .unavailable }

        guard let window = textWindow(in: element, around: hitRange.location)
                ?? (attribute(element, kAXValueAttribute) as? String).map({ ($0, 0) }) else { return .unavailable }
        let (text, textStart) = window

        guard let match = wordRange(in: text, containing: hitRange.location - textStart) else {
            // 点在空白、标点或文字末尾之后：能取到该处字符的位置，说明应用能核对位置，按不是文字处理。
            let length = (text as NSString).length
            guard length > 0 else { return .unavailable }
            let location = min(max(hitRange.location, textStart), textStart + length - 1)
            let characterBounds = axValue(range: CFRange(location: location, length: 1))
                .flatMap { rect(attribute(element, kAXBoundsForRangeParameterizedAttribute, parameter: $0)) }
            return usable(characterBounds) == nil ? .unavailable : .notOnText
        }
        let word = (text as NSString).substring(with: match)
        let bounds = axValue(range: CFRange(location: textStart + match.location, length: match.length))
            .flatMap { rect(attribute(element, kAXBoundsForRangeParameterizedAttribute, parameter: $0)) }
        return hitWord(word, bounds: bounds, point: point, method: "character range")
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

    /// 按坐标取文本标记（WebKit 支持；Chrome 声明支持却取不到，由双击选词兜底）。
    private static func wordUsingTextMarkers(in element: AXUIElement, at point: CGPoint) -> WordLookup {
        guard let pointValue = axValue(point: point),
              let marker = attribute(element, "AXTextMarkerForPosition", parameter: pointValue) else { return .unavailable }
        return word(aroundMarker: marker, in: element, at: point, method: "text marker")
    }

    private static func word(
        aroundMarker marker: CFTypeRef,
        in element: AXUIElement,
        at point: CGPoint,
        method: String
    ) -> WordLookup {
        var lookup = WordLookup.unavailable
        // 点在单词中间时右侧单词区间即该单词；点在词尾边界时再看左侧单词。
        for wordAttribute in ["AXRightWordTextMarkerRangeForTextMarker", "AXLeftWordTextMarkerRangeForTextMarker"] {
            guard let markerRange = attribute(element, wordAttribute, parameter: marker),
                  let word = attribute(element, "AXStringForTextMarkerRange", parameter: markerRange) as? String
            else { continue }
            let bounds = rect(attribute(element, "AXBoundsForTextMarkerRange", parameter: markerRange))
            lookup = merged(lookup, hitWord(word, bounds: bounds, point: point, method: method))
            if case .found = lookup {
                return lookup
            }
        }
        return lookup
    }

    /// 坐标反查得到的位置并不总在点按处：点在空白处时系统会返回最近的字符，部分网页实现
    /// 只能定位到文字节点开头。因此要求取到单词的位置并确实覆盖点按位置：取不到位置就无法核对，
    /// 宁可交给双击选词也不翻错词；位置不覆盖点按处或单词不含字母、数字时按不是文字处理。
    private static func hitWord(_ word: String, bounds: CGRect?, point: CGPoint, method: String) -> WordLookup {
        guard let bounds = usable(bounds) else {
            logger.debug("Rejected word via \(method, privacy: .public): no bounds, point \(Self.describe(point), privacy: .public)")
            return .unavailable
        }
        guard bounds.insetBy(dx: -hitTolerance, dy: -hitTolerance).contains(point) else {
            logger.debug(
                "Rejected word via \(method, privacy: .public): bounds \(Self.describe(bounds), privacy: .public) miss point \(Self.describe(point), privacy: .public)"
            )
            return .notOnText
        }
        guard let cleaned = cleaned(word),
              cleaned.unicodeScalars.contains(where: CharacterSet.alphanumerics.contains) else { return .notOnText }
        logger.debug(
            "Captured word via \(method, privacy: .public): bounds \(Self.describe(bounds), privacy: .public), point \(Self.describe(point), privacy: .public)"
        )
        return .found(CapturedText(text: cleaned, source: .word, screenRect: bounds))
    }

    private static func describe(_ point: CGPoint) -> String {
        String(format: "(%.0f, %.0f)", point.x, point.y)
    }

    private static func describe(_ rect: CGRect) -> String {
        String(format: "(%.0f, %.0f, %.0f×%.0f)", rect.minX, rect.minY, rect.width, rect.height)
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
        var result = CFRange()
        return unpack(value, .cfRange, into: &result) ? result : nil
    }

    private static func rect(_ value: CFTypeRef?) -> CGRect? {
        var result = CGRect.zero
        return unpack(value, .cgRect, into: &result) ? result : nil
    }

    /// 把 AXValue 中的结构体取到 `pointer` 指向的变量；值不是 AXValue 或类型不符时返回 false。
    /// 不写成泛型：`AXValueGetValue` 按字节写入，只能传给纯数值的结构体（CGPoint、CGSize、CGRect、CFRange）。
    private static func unpack(_ value: CFTypeRef?, _ type: AXValueType, into pointer: UnsafeMutableRawPointer) -> Bool {
        guard let value, CFGetTypeID(value) == AXValueGetTypeID() else { return false }
        return AXValueGetValue(value as! AXValue, type, pointer)
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
