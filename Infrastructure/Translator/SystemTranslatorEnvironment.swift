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
    /// 请求权限后等待系统授权提示出现的时长：提示框出现时会切到前台，这段时间内没有其他应用
    /// 切到前台，说明系统没有弹出提示。
    private static let promptAppearanceTimeout: Duration = .seconds(1)

    /// 一次请求的收尾：系统授权提示出现即结束，等待超时则打开设置页。
    private var pendingRequest: Task<Void, Never>?
    private var activationObserver: (any NSObjectProtocol)?

    var isAccessibilityTrusted: Bool {
        AXIsProcessTrusted()
    }

    func requestAccessibilityAccess() {
        guard pendingRequest == nil else { return }
        // 键名即 kAXTrustedCheckOptionPrompt 的取值；直接引用该 C 全局变量会触发严格并发检查。
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        guard !AXIsProcessTrustedWithOptions(options) else { return }

        // 系统只在 OI 尚未出现在辅助功能列表中时弹出授权提示（并把 OI 加入列表），提示自带「打开系统设置」，
        // 此时再打开设置页会抢在用户作答前盖住提示、抢走焦点。之后 OI 已在列表中（未勾选），系统不再提示，
        // 才需要直接打开设置页。无从查询 OI 是否已在列表中，改为观察提示框：它出现时会切到前台。
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let processIdentifier = application?.processIdentifier
            MainActor.assumeIsolated {
                guard processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
                self?.finishAccessibilityRequest(opensSettings: false)
            }
        }
        pendingRequest = Task { [weak self] in
            try? await Task.sleep(for: Self.promptAppearanceTimeout)
            guard !Task.isCancelled else { return }
            self?.finishAccessibilityRequest(opensSettings: true)
        }
    }

    func openTrackpadSettings() {
        open(Self.trackpadSettingsURL)
    }

    private func finishAccessibilityRequest(opensSettings: Bool) {
        pendingRequest?.cancel()
        pendingRequest = nil
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
            self.activationObserver = nil
        }
        guard opensSettings, !AXIsProcessTrusted() else { return }
        open(Self.accessibilitySettingsURL)
    }

    private func open(_ url: URL?) {
        guard let url else { return }
        NSWorkspace.shared.open(url)
    }
}
