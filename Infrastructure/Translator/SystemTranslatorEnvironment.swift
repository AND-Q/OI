import AppKit
import ApplicationServices

/// 辅助功能权限与触控板设置的系统实现。
@MainActor
final class SystemTranslatorEnvironment: TranslatorEnvironmentHandling {
    private static let accessibilitySettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
    )
    private static let trackpadSettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.Trackpad-Settings.extension"
    )

    var isAccessibilityTrusted: Bool {
        AXIsProcessTrusted()
    }

    func requestAccessibilityAccess() {
        // 键名即 kAXTrustedCheckOptionPrompt 的取值；直接引用该 C 全局变量会触发严格并发检查。
        // 首次请求时系统弹出授权提示并把 OI 加入辅助功能列表，之后不再弹窗，所以同时打开设置页。
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        guard !AXIsProcessTrustedWithOptions(options) else { return }
        open(Self.accessibilitySettingsURL)
    }

    func openTrackpadSettings() {
        open(Self.trackpadSettingsURL)
    }

    private func open(_ url: URL?) {
        guard let url else { return }
        NSWorkspace.shared.open(url)
    }
}
