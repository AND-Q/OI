import AppKit
import ApplicationServices
import Carbon.HIToolbox
import os

/// 用辅助功能 API 读取其他应用中的文字，读不到选区时模拟 ⌘C，用剪贴板兜底。
/// 原生文本控件走字符区间属性（`AXSelectedText`、`AXRangeForPosition` 等）；WebKit 与 Chromium
/// 的网页内容不提供字符区间，改用文本标记（text marker）属性。安全输入框（密码）一律不读取。
struct AccessibilityTextCapturer: TextCapturing {
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
    /// 模拟 ⌘C 后等待前台应用写入剪贴板的上限：Chrome 等跨进程复制，写入稍有延迟；
    /// 没有选中文字时应用不改动剪贴板，等满即放弃。
    private static let copyTimeout: Duration = .milliseconds(300)
    private static let copyPollInterval: Duration = .milliseconds(10)
    /// 正在模拟 ⌘C：连按快捷键时后一次不再复制，以免把前一次复制出的选区当作剪贴板原有的内容保存并恢复。
    @MainActor private static var isCopying = false
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

    /// 模拟 ⌘C 让前台应用自己复制选中的文字，读出后立即恢复剪贴板原来的内容（剪贴板管理器仍可能记下这一次复制）。
    /// 没有选中文字时应用不改动剪贴板，等待超时即返回 nil。OI 自己的窗口（如固定的气泡）是 key 时
    /// 按键会发给 OI，不模拟。
    @MainActor
    func copiedSelection() async -> CapturedText? {
        guard !Self.isCopying, NSApp.keyWindow == nil, Self.frontmostForeignProcessID() != nil,
              !IsSecureEventInputEnabled() else { return nil }
        Self.isCopying = true
        defer { Self.isCopying = false }
        let pasteboard = NSPasteboard.general
        let changeCount = pasteboard.changeCount
        let savedItems = Self.savedItems(of: pasteboard)
        Self.postCopyShortcut()

        let clock = ContinuousClock()
        let deadline = clock.now + Self.copyTimeout
        // 应用先清空剪贴板再写入内容，两步之间读不到文字，等到有内容为止。
        while pasteboard.changeCount == changeCount || (pasteboard.types ?? []).isEmpty,
              clock.now < deadline, !Task.isCancelled {
            try? await Task.sleep(for: Self.copyPollInterval)
        }
        guard pasteboard.changeCount != changeCount else { return nil }
        let copied = Self.copiedText(in: pasteboard)
        Self.restore(savedItems, to: pasteboard)
        guard let copied, let cleaned = CapturedText.cleaned(copied) else { return nil }
        return CapturedText(text: cleaned, source: .selection, screenRect: nil)
    }

    @MainActor
    func clipboardText() -> CapturedText? {
        let pasteboard = NSPasteboard.general
        if Self.isConcealed(pasteboard) { return nil }
        guard let text = pasteboard.string(forType: .string), let cleaned = CapturedText.cleaned(text) else {
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

    // MARK: - 读取选区

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
              let cleaned = CapturedText.cleaned(text) else { return nil }
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
                guard let cleaned = CapturedText.cleaned(text) else { return nil }
                let bounds = rect(attribute(current, "AXBoundsForTextMarkerRange", parameter: markerRange))
                return CapturedText(text: cleaned, source: .selection, screenRect: usable(bounds))
            }
            candidate = uiElement(attribute(current, kAXParentAttribute))
        }
        return nil
    }

    // MARK: - 按坐标取词

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
            """
            No word under force click (\(reason, privacy: .public)) in \(role, privacy: .public) \
            of \(applicationName, privacy: .public); parameterized attributes: \(supported, privacy: .public)
            """
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
                """
                Rejected word via \(method, privacy: .public): bounds \(Self.describe(bounds), privacy: .public) \
                miss point \(Self.describe(point), privacy: .public)
                """
            )
            return .notOnText
        }
        guard let cleaned = CapturedText.cleaned(word),
              cleaned.unicodeScalars.contains(where: CharacterSet.alphanumerics.contains) else { return .notOnText }
        logger.debug(
            """
            Captured word via \(method, privacy: .public): bounds \(Self.describe(bounds), privacy: .public), \
            point \(Self.describe(point), privacy: .public)
            """
        )
        return .found(CapturedText(text: cleaned, source: .word, screenRect: bounds))
    }

    private static func describe(_ point: CGPoint) -> String {
        String(format: "(%.0f, %.0f)", point.x, point.y)
    }

    private static func describe(_ rect: CGRect) -> String {
        String(format: "(%.0f, %.0f, %.0f×%.0f)", rect.minX, rect.minY, rect.width, rect.height)
    }

    // MARK: - 模拟 ⌘C

    /// 剪贴板现有内容的副本：逐项、逐类型读出数据。原来的各项属于剪贴板，清空后不能直接写回。
    @MainActor
    static func savedItems(of pasteboard: NSPasteboard) -> [NSPasteboardItem] {
        (pasteboard.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) {
                    copy.setData(data, forType: type)
                }
            }
            return copy
        }
    }

    /// 把 `savedItems(of:)` 保存的内容写回剪贴板。
    @MainActor
    static func restore(_ items: [NSPasteboardItem], to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        if !items.isEmpty {
            pasteboard.writeObjects(items)
        }
    }

    /// 模拟 ⌘C 后复制出的文字。复制出的是文件（如在 Finder 中选中了文件）或被标记为敏感的内容时为 nil。
    @MainActor
    static func copiedText(in pasteboard: NSPasteboard) -> String? {
        guard !isConcealed(pasteboard), pasteboard.types?.contains(.fileURL) != true else { return nil }
        return pasteboard.string(forType: .string)
    }

    /// nspasteboard.org 约定：密码管理器复制的敏感内容带此标记，不读取也就不会发送出去。
    @MainActor
    private static func isConcealed(_ pasteboard: NSPasteboard) -> Bool {
        pasteboard.types?.contains(NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")) == true
    }

    /// 模拟按下并松开 ⌘C。只带 ⌘：用户此时可能还按着翻译快捷键的修饰键（如 ⌥D 的 ⌥），
    /// 混入后会变成 ⌥⌘C 等应用的其他快捷键。
    private static func postCopyShortcut() {
        let source = CGEventSource(stateID: .privateState)
        for isKeyDown in [true, false] {
            guard let event = CGEvent(
                keyboardEventSource: source,
                virtualKey: CGKeyCode(kVK_ANSI_C),
                keyDown: isKeyDown
            ) else { continue }
            event.flags = .maskCommand
            event.post(tap: .cghidEventTap)
        }
    }

    // MARK: - 辅助功能工具方法

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
