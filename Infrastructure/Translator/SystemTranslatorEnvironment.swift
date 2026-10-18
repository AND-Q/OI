import AppKit
import ApplicationServices

/// 辅助功能、屏幕录制权限与触控板设置的系统实现。
@MainActor
final class SystemTranslatorEnvironment: TranslatorEnvironmentHandling {
    /// 需要用户在「隐私与安全性」中授予的权限。
    private enum Permission {
        case accessibility
        case screenCapture

        var isGranted: Bool {
            switch self {
            case .accessibility: AXIsProcessTrusted()
            case .screenCapture: CGPreflightScreenCaptureAccess()
            }
        }

        var settingsURL: URL? {
            switch self {
            case .accessibility:
                URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
            case .screenCapture:
                URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
            }
        }

        /// 请求权限，返回是否已获授权。未授权时系统弹出授权提示（并把 OI 加入对应权限列表）：
        /// 辅助功能每次请求都会弹出（点过「拒绝」也一样），屏幕录制只在第一次请求时弹出。
        func request() -> Bool {
            switch self {
            case .accessibility:
                // 键名即 kAXTrustedCheckOptionPrompt 的取值；直接引用该 C 全局变量会触发严格并发检查。
                AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
            case .screenCapture:
                CGRequestScreenCaptureAccess()
            }
        }
    }

    private static let trackpadSettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.Trackpad-Settings.extension"
    )
    /// 请求权限后等待系统授权提示出现的时长：提示框出现时会切到前台，这段时间内没有其他应用
    /// 切到前台，说明系统没有弹出提示。
    private static let promptAppearanceTimeout: Duration = .seconds(1)

    /// 一次请求的收尾：系统授权提示出现即结束，等待超时则打开设置页。
    private var pendingRequest: Task<Void, Never>?
    private var activationObserver: (any NSObjectProtocol)?
    /// 本次运行中已向系统请求过的权限：再次请求时不再经系统授权提示，直接打开设置页。
    private var requestedPermissions: Set<Permission> = []

    var isAccessibilityTrusted: Bool {
        Permission.accessibility.isGranted
    }

    var isScreenCaptureTrusted: Bool {
        Permission.screenCapture.isGranted
    }

    func requestAccessibilityAccess() {
        requestAccess(.accessibility)
    }

    func requestScreenCaptureAccess() {
        requestAccess(.screenCapture)
    }

    func openTrackpadSettings() {
        open(Self.trackpadSettingsURL)
    }

    private func requestAccess(_ permission: Permission) {
        guard pendingRequest == nil else { return }
        // 同一次运行只经系统授权提示请求一次，之后直接打开设置页，免得每次都先点掉辅助功能的提示。
        // 不跨运行记住：重新打开 OI 后再经提示请求一次，OI 被移出列表或重新编译（临时签名，系统视为
        // 另一个程序）后仍能由提示加回列表。
        guard requestedPermissions.insert(permission).inserted else {
            if !permission.isGranted {
                open(permission.settingsURL)
            }
            return
        }
        guard !permission.request() else { return }

        // 提示自带「打开系统设置」，此时再打开设置页会抢在用户作答前盖住提示、抢走焦点；系统没有弹出提示
        // （屏幕录制此前已请求过）时才需要直接打开设置页。无从预知是否会弹出，改为观察提示框：它出现时会切到前台。
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let processIdentifier = application?.processIdentifier
            MainActor.assumeIsolated {
                guard processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
                self?.finishRequest(for: permission, opensSettings: false)
            }
        }
        pendingRequest = Task { [weak self] in
            try? await Task.sleep(for: Self.promptAppearanceTimeout)
            guard !Task.isCancelled else { return }
            self?.finishRequest(for: permission, opensSettings: true)
        }
    }

    private func finishRequest(for permission: Permission, opensSettings: Bool) {
        pendingRequest?.cancel()
        pendingRequest = nil
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
            self.activationObserver = nil
        }
        guard opensSettings, !permission.isGranted else { return }
        open(permission.settingsURL)
    }

    private func open(_ url: URL?) {
        guard let url else { return }
        NSWorkspace.shared.open(url)
    }
}
