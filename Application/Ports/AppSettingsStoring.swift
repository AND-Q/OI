import Foundation

/// 应用级用户设置（设置面板读写）。开机自启动不在此存储：其状态由系统登录项持有，
/// 设置面板实时读取，见 `LoginItemControlling`。
struct AppSettings: Sendable, Equatable {
    /// 开机静默启动：启动时仅驻留菜单栏，不自动呼出启动器面板。
    var isSilentLaunchEnabled: Bool = true
    /// Spotlight 文件与文件夹搜索。
    var isFileSearchEnabled: Bool = true
    /// 启动历史排序：记录启动次数与最近使用时间，优化常用应用排序。
    var isUsageRankingEnabled: Bool = true
}

/// 应用级设置的持久化端口。设置值极小且只在主线程读写，端口按同步设计。
@MainActor
protocol AppSettingsStoring: AnyObject {
    func load() -> AppSettings
    func save(_ settings: AppSettings)
}

/// 用作默认实现和测试用的内存存储；不做任何持久化。
@MainActor
final class MemoryAppSettingsStore: AppSettingsStoring {
    private var storedSettings: AppSettings

    init(initial: AppSettings = AppSettings()) {
        storedSettings = initial
    }

    func load() -> AppSettings {
        storedSettings
    }

    func save(_ settings: AppSettings) {
        storedSettings = settings
    }
}
