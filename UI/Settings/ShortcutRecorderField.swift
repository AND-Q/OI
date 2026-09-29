import AppKit
import Carbon.HIToolbox
import SwiftUI

/// 设置面板中的呼出快捷键录制控件：
/// 点按进入录制，按下含 ⌘/⌥/⌃ 的组合即提交；Esc 或点击其他位置取消。
/// 录制期间用 NSEvent 本地监听捕获按键（无需辅助功能权限），不影响系统全局事件。
/// 因 NSEvent 属 UI 专属类型，本控件与设置窗口壳同置于 UI 层。
struct ShortcutRecorderField: View {
    /// 当前生效的组合，用于未录制时的键帽展示。
    let shortcut: LauncherShortcut
    /// 提交录到的组合；激活失败时由 ViewModel 回滚设置并提示。
    let onCommit: (LauncherShortcut) -> Void

    @State private var isRecording = false
    @State private var hint: String?
    @State private var monitor: Any?

    var body: some View {
        Button {
            if isRecording {
                stopRecording()
            } else {
                startRecording()
            }
        } label: {
            label
        }
        .buttonStyle(.plain)
        .onDisappear { stopRecording() }
        // 设置窗口失去 key（切走应用或呼出启动器面板）即退出录制，
        // 避免遗留的本地监听器吞掉用户回来后的第一次输入。
        .onReceive(
            NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)
        ) { _ in
            stopRecording()
        }
    }

    @ViewBuilder
    private var label: some View {
        if isRecording {
            HStack(spacing: 6) {
                Image(systemName: "record.circle")
                Text(hint ?? "按下新的快捷键")
                    .foregroundStyle(hint == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.red))
            }
            .font(.callout)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                Capsule().fill(Color.accentColor.opacity(0.12))
            )
            .overlay(
                Capsule().strokeBorder(Color.accentColor, lineWidth: 1.5)
            )
        } else {
            HStack(spacing: 6) {
                ShortcutKeyCaps(shortcut: shortcut)
                Image(systemName: "pencil")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 3)
        }
    }

    /// 开始录制；重复点按会先收掉上一个监听器再重新开始。
    private func startRecording() {
        // 幂等保护：无论触发路径如何，至多只允许一个监听器存活。
        stopRecording()
        isRecording = true
        hint = nil
        monitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { event in
            handle(event)
        }
    }

    private func stopRecording() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
        isRecording = false
        hint = nil
    }

    /// 返回 nil 表示消费事件，避免录制期间误触其他控件。
    private func handle(_ event: NSEvent) -> NSEvent? {
        switch event.type {
        case .keyDown:
            return handleKeyDown(event)
        default:
            stopRecording()
            return nil
        }
    }

    private func handleKeyDown(_ event: NSEvent) -> NSEvent? {
        let modifiers = Self.carbonModifiers(from: event.modifierFlags)
        // 无修饰键的 Esc 退出录制；带修饰键的 Esc 是合法组合，照常提交。
        if event.keyCode == UInt16(kVK_Escape), modifiers == 0 {
            stopRecording()
            return nil
        }
        let recorded = LauncherShortcut(keyCode: UInt32(event.keyCode), modifiers: modifiers)
        guard recorded.isValid else {
            hint = "需包含 ⌘、⌥ 或 ⌃ 修饰键"
            return nil
        }
        stopRecording()
        onCommit(recorded)
        return nil
    }

    private static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var modifiers: UInt32 = 0
        if flags.contains(.command) { modifiers |= UInt32(cmdKey) }
        if flags.contains(.option) { modifiers |= UInt32(optionKey) }
        if flags.contains(.control) { modifiers |= UInt32(controlKey) }
        if flags.contains(.shift) { modifiers |= UInt32(shiftKey) }
        return modifiers
    }
}

/// 快捷键的键帽展示：修饰键符号与按键名逐个渲染为胶囊。
struct ShortcutKeyCaps: View {
    let shortcut: LauncherShortcut

    var body: some View {
        HStack(spacing: 4) {
            ForEach(
                ShortcutFormatter.modifierSymbols(for: shortcut.modifiers)
                    + [ShortcutFormatter.keyName(for: shortcut.keyCode)],
                id: \.self
            ) { symbol in
                Text(symbol)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.primary.opacity(0.08)))
                    .overlay(Capsule().strokeBorder(Color.primary.opacity(0.15)))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(ShortcutFormatter.displayName(for: shortcut))
    }
}
