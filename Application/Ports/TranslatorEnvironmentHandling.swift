import Foundation

/// 划词翻译依赖的系统环境：读取其他应用文字所需的辅助功能权限，
/// 以及触控板「用力点按」相关系统设置的入口。
@MainActor
protocol TranslatorEnvironmentHandling: AnyObject {
    var isAccessibilityTrusted: Bool { get }
    /// 请求辅助功能权限：系统弹出授权提示时交给提示引导（提示中可打开系统设置）；
    /// 系统不再提示（OI 已在辅助功能列表中但未勾选）时直接打开「隐私与安全性 → 辅助功能」。
    func requestAccessibilityAccess()
    /// 打开「系统设置 → 触控板」，用于关闭系统查询的用力点按、确认触感反馈已开启。
    func openTrackpadSettings()
}

/// 用作默认实现和测试用的固定状态实现；不访问系统，只记录调用次数。
@MainActor
final class MemoryTranslatorEnvironment: TranslatorEnvironmentHandling {
    var isAccessibilityTrusted: Bool
    private(set) var accessibilityRequestCount = 0
    private(set) var trackpadSettingsOpenCount = 0

    init(isAccessibilityTrusted: Bool = false) {
        self.isAccessibilityTrusted = isAccessibilityTrusted
    }

    func requestAccessibilityAccess() {
        accessibilityRequestCount += 1
    }

    func openTrackpadSettings() {
        trackpadSettingsOpenCount += 1
    }
}
