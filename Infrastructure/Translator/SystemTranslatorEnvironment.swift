import AppKit
import ApplicationServices

/// 辅助功能、屏幕录制权限与触控板设置的系统实现。
@MainActor
final class SystemTranslatorEnvironment: TranslatorEnvironmentHandling {
    private static let accessibilitySettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
    )
    private static let screenCaptureSettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
    )
    private static let trackpadSettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.Trackpad-Settings.extension"
    )

    var isAccessibilityTrusted: Bool {
        AXIsProcessTrusted()
    }

    var isScreenCaptureAllowed: Bool {
        CGPreflightScreenCaptureAccess()
    }

    func requestScreenCaptureAccess() {
        // 与辅助功能相同：系统只在首次请求时弹出授权提示，之后直接打开设置页。
        guard !CGRequestScreenCaptureAccess() else { return }
        open(Self.screenCaptureSettingsURL)
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
