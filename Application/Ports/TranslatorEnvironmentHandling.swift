import Foundation

/// 划词翻译依赖的系统环境：读取其他应用文字所需的辅助功能权限、截图识字所需的屏幕录制权限，
/// 以及触控板「用力点按」相关系统设置的入口。
@MainActor
protocol TranslatorEnvironmentHandling: AnyObject {
    var isAccessibilityTrusted: Bool { get }
    var isScreenCaptureAllowed: Bool { get }
    /// 请求辅助功能权限：弹出系统授权提示并打开「隐私与安全性 → 辅助功能」。
    func requestAccessibilityAccess()
    /// 请求屏幕录制权限：弹出系统授权提示并打开「隐私与安全性 → 屏幕与系统录音」。
    func requestScreenCaptureAccess()
    /// 打开「系统设置 → 触控板」，用于关闭系统查询的用力点按、确认触感反馈已开启。
    func openTrackpadSettings()
}

/// 用作默认实现和测试用的固定状态实现；不访问系统，只记录调用次数。
@MainActor
final class MemoryTranslatorEnvironment: TranslatorEnvironmentHandling {
    var isAccessibilityTrusted: Bool
    var isScreenCaptureAllowed: Bool
    private(set) var accessibilityRequestCount = 0
    private(set) var screenCaptureRequestCount = 0
    private(set) var trackpadSettingsOpenCount = 0

    init(isAccessibilityTrusted: Bool = false, isScreenCaptureAllowed: Bool = false) {
        self.isAccessibilityTrusted = isAccessibilityTrusted
        self.isScreenCaptureAllowed = isScreenCaptureAllowed
    }

    func requestAccessibilityAccess() {
        accessibilityRequestCount += 1
    }

    func requestScreenCaptureAccess() {
        screenCaptureRequestCount += 1
    }

    func openTrackpadSettings() {
        trackpadSettingsOpenCount += 1
    }
}
