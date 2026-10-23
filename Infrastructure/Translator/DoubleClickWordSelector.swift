import AppKit
import ApplicationServices
import Carbon.HIToolbox
import os

/// 双击选词：辅助功能取不到光标下的文字时（如 Chrome 网页、VS Code 编辑器），等手指抬起后在点按处模拟双击，
/// 让目标应用自己选中该处的单词，用辅助功能读出选区，再单击一次取消选中。不按 ⌘C、不读写剪贴板。
/// 用力点按本身会把光标移到点按处，取词结束后目标应用与普通单击一下的状态相同。
/// 取到单词却读不到它的位置时（如 VS Code）OI 画不出高亮，改为保留应用自己的选中状态标出取的是哪个词。
struct DoubleClickWordSelector: WordSelecting {
    /// 单词最多的字符数：超过时多半是双击选中了整段（如不以空格分词的长句），不当作单词。
    static let maximumWordLength = 64
    /// 按住不放超过此时长视为取消。
    private static let releaseTimeout: Duration = .seconds(3)
    /// 按下到抬起之间指针移动超过此距离视为拖拽，不取词。
    private static let dragThreshold: CGFloat = 5
    /// 点按未激活的窗口时，等待其应用切到前台的上限。
    private static let activationTimeout: Duration = .milliseconds(300)
    /// 双击后等待目标应用更新选区的上限。
    private static let selectionTimeout: Duration = .milliseconds(300)
    private static let releasePollInterval: Duration = .milliseconds(10)
    private static let selectionPollInterval: Duration = .milliseconds(20)
    /// 模拟的按下与抬起之间的间隔，接近真实点击的节奏。
    private static let clickEventInterval: Duration = .milliseconds(5)
    /// 判定选区覆盖点按位置时，选区向外放宽的距离。
    private static let hitTolerance: CGFloat = 3
    /// 向上读取角色的最大层数：网页结构层级较深，判断列表行时需要找到上层的 AXWebArea。
    private static let maximumAncestorDepth = 32
    private static let messagingTimeout: Float = 0.5
    /// 不双击的应用：Finder（含桌面）双击会打开文件，Dock 是启动入口。
    private static let excludedBundleIdentifiers: Set<String> = ["com.apple.finder", "com.apple.dock"]
    /// 可操作控件：用力点按那一次真实点击已经触发过它们，再双击只会重复触发。
    private static let controlRoles: Set<String> = [
        "AXLink", "AXButton", "AXMenuButton", "AXPopUpButton", "AXMenuItem", "AXMenuBarItem",
        "AXCheckBox", "AXRadioButton", "AXDisclosureTriangle", "AXSlider", "AXIncrementor", "AXImage",
    ]
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "OI", category: "Translator")

    /// 点按处元素所属的进程与角色（自身在前，依次向上）。
    private struct HitTarget: Sendable {
        let processID: pid_t
        let roles: [String]
        let isSecureTextField: Bool
    }

    /// 读取双击后的选区。
    let textCapturer: any TextCapturing

    func selectWord(at point: CGPoint) async -> CapturedText? {
        guard await Self.waitForRelease(near: point) else { return nil }
        let ownProcessID = ProcessInfo.processInfo.processIdentifier
        guard let target = await Task.detached(priority: .userInitiated, operation: { Self.hitTarget(at: point) }).value,
              target.processID != ownProcessID else {
            Self.logger.debug("Double click skipped: no element of another app under force click")
            return nil
        }
        guard !target.isSecureTextField, !IsSecureEventInputEnabled() else {
            Self.logger.debug("Double click skipped: secure input")
            return nil
        }
        let bundleIdentifier = await MainActor.run {
            NSRunningApplication(processIdentifier: target.processID)?.bundleIdentifier
        }
        guard Self.canDoubleClick(bundleIdentifier: bundleIdentifier, roles: target.roles) else {
            Self.logger.debug(
                "Double click skipped in \(bundleIdentifier ?? "unknown", privacy: .public): \(target.roles.joined(separator: " < "), privacy: .public)"
            )
            return nil
        }
        guard await Self.waitUntilFrontmost(target.processID) else {
            Self.logger.debug("Double click skipped: \(bundleIdentifier ?? "unknown", privacy: .public) did not become frontmost")
            return nil
        }

        let previous = await textCapturer.selectedText()
        await Self.postClick(at: point, count: 2)
        let word = await selectedWord(at: point, previous: previous)
        // 取到单词但读不到位置时保留选中状态，作为取到哪个词的标记；其余情况单击一次取消选中：
        // 双击可能选中了空白或整段，取消选中后目标应用回到普通单击后的状态。
        // 须在弹出气泡前完成，否则这次单击会被当作点到气泡外部而收起气泡。
        let keepsSelection = word != nil && word?.screenRect == nil
        if !keepsSelection {
            await Self.postClick(at: point, count: 1)
        }
        if word != nil {
            Self.logger.debug(
                "Captured word via double click in \(bundleIdentifier ?? "unknown", privacy: .public)\(keepsSelection ? ", selection kept as marker" : "", privacy: .public)"
            )
        } else {
            Self.logger.debug("No word selected after double click in \(bundleIdentifier ?? "unknown", privacy: .public)")
        }
        return word
    }

    /// 点按处能否模拟双击。`roles` 为点按处元素及其上层的角色，自身在前。
    /// Finder、Dock 与可操作控件不双击；列表行只在网页表格中双击——
    /// 树形列表与原生列表、表格的行双击通常是「打开」。
    static func canDoubleClick(bundleIdentifier: String?, roles: [String]) -> Bool {
        if let bundleIdentifier, excludedBundleIdentifiers.contains(bundleIdentifier) {
            return false
        }
        guard !roles.contains(where: { controlRoles.contains($0) }) else { return false }
        guard let rowIndex = roles.firstIndex(of: "AXRow") else { return true }
        let containers = roles[(rowIndex + 1)...]
        return !containers.contains("AXOutline") && containers.contains("AXWebArea")
    }

    /// 双击后读到的选区能否当作点按处的单词：须与双击前的选区不同，是不含换行、
    /// 不超过 `maximumWordLength` 个字符且含字母或数字的单个词；能取到位置时还须覆盖点按位置。
    static func acceptedWord(_ selection: CapturedText?, previous: CapturedText?, at point: CGPoint) -> CapturedText? {
        guard let selection, selection != previous else { return nil }
        let text = selection.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty,
              text.count <= maximumWordLength,
              !text.contains(where: \.isNewline),
              text.unicodeScalars.contains(where: CharacterSet.alphanumerics.contains) else { return nil }
        if let rect = selection.screenRect, !rect.insetBy(dx: -hitTolerance, dy: -hitTolerance).contains(point) {
            return nil
        }
        return CapturedText(text: text, source: .word, screenRect: selection.screenRect)
    }

    /// 双击后目标应用异步更新选区（Chromium 等跨进程更新辅助功能树），轮询到点按处的新单词或超时为止。
    private func selectedWord(at point: CGPoint, previous: CapturedText?) async -> CapturedText? {
        let clock = ContinuousClock()
        let deadline = clock.now + Self.selectionTimeout
        repeat {
            try? await Task.sleep(for: Self.selectionPollInterval)
            let selection = await textCapturer.selectedText()
            if let word = Self.acceptedWord(selection, previous: previous, at: point) {
                return word
            }
        } while clock.now < deadline && !Task.isCancelled
        return nil
    }

    /// 等手指抬起：按住期间模拟点击会打乱目标应用的拖拽状态。按住超时或抬起时指针已移开（拖拽）则放弃。
    private static func waitForRelease(near point: CGPoint) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + releaseTimeout
        while CGEventSource.buttonState(.combinedSessionState, button: .left) {
            guard clock.now < deadline, !Task.isCancelled else {
                logger.debug("Double click skipped: button not released")
                return false
            }
            try? await Task.sleep(for: releasePollInterval)
        }
        let location = CGEvent(source: nil)?.location ?? point
        guard hypot(location.x - point.x, location.y - point.y) <= dragThreshold else {
            logger.debug("Double click skipped: pointer moved during force click")
            return false
        }
        return true
    }

    /// 点按未激活的窗口时，目标应用在这次点击后才切到前台；读选区以前台应用为准，须等它切换完成。
    private static func waitUntilFrontmost(_ processID: pid_t) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + activationTimeout
        while await MainActor.run(body: { NSWorkspace.shared.frontmostApplication?.processIdentifier }) != processID {
            guard clock.now < deadline, !Task.isCancelled else { return false }
            try? await Task.sleep(for: selectionPollInterval)
        }
        return true
    }

    /// 在 `point` 处模拟单击（`count` 为 1）或双击（为 2）。每次按下与抬起都标明是第几次点击，
    /// 目标应用据此识别双击；取消选中的单击标为第 1 次，不与刚才的双击连成三击。
    /// 清除修饰键，避免用户按着 ⌘ 等键时变成多光标、新标签页打开等操作。
    private static func postClick(at point: CGPoint, count: Int) async {
        for clickState in 1...count {
            for type in [CGEventType.leftMouseDown, .leftMouseUp] {
                guard let event = CGEvent(
                    mouseEventSource: nil,
                    mouseType: type,
                    mouseCursorPosition: point,
                    mouseButton: .left
                ) else { continue }
                event.flags = []
                event.setIntegerValueField(.mouseEventClickState, value: Int64(clickState))
                event.post(tap: .cghidEventTap)
                try? await Task.sleep(for: clickEventInterval)
            }
        }
    }

    // MARK: - 辅助功能工具方法

    private static func hitTarget(at point: CGPoint) -> HitTarget? {
        let systemWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWide, messagingTimeout)
        var hit: AXUIElement?
        var processID: pid_t = 0
        guard AXUIElementCopyElementAtPosition(systemWide, Float(point.x), Float(point.y), &hit) == .success,
              let hit,
              AXUIElementGetPid(hit, &processID) == .success else { return nil }
        var roles: [String] = []
        var current: AXUIElement? = hit
        while let element = current, roles.count < maximumAncestorDepth {
            AXUIElementSetMessagingTimeout(element, messagingTimeout)
            roles.append(attribute(element, kAXRoleAttribute) as? String ?? "unknown")
            current = uiElement(attribute(element, kAXParentAttribute))
        }
        let isSecureTextField = (attribute(hit, kAXSubroleAttribute) as? String) == kAXSecureTextFieldSubrole
        return HitTarget(processID: processID, roles: roles, isSecureTextField: isSecureTextField)
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    private static func uiElement(_ value: CFTypeRef?) -> AXUIElement? {
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }
}
