import Foundation

/// 设置窗口侧边栏的分类：每个分类一页，右侧只显示当前分类的设置项。
enum SettingsCategory: String, CaseIterable, Identifiable {
    case general
    case search
    case quickAI
    case translator
    case environment

    var id: Self { self }

    var title: String {
        switch self {
        case .general: String(localized: "通用")
        case .search: String(localized: "搜索")
        case .quickAI: "Quick AI"
        case .translator: String(localized: "划词翻译")
        case .environment: String(localized: "取词环境")
        }
    }

    /// 侧边栏图标（SF Symbols 名称）。
    var symbolName: String {
        switch self {
        case .general: "gearshape.fill"
        case .search: "magnifyingglass"
        case .quickAI: "sparkles"
        case .translator: "translate"
        case .environment: "hand.raised.fill"
        }
    }

    /// 页内的分组标题与设置项名称，供侧边栏搜索匹配；与设置页上显示的文字保持一致。
    var itemNames: [String] {
        let names: [String.LocalizationValue] = switch self {
        case .general:
            ["开机自启动", "开机静默启动", "界面语言", "快捷键", "呼出快捷键"]
        case .search:
            ["文件与文件夹搜索", "启动历史排序", "网页搜索引擎"]
        case .quickAI:
            ["接口地址", "模型", "获取模型", "思考强度", "API Key", "测试连接"]
        case .translator:
            [
                "取词与快捷键", "触控板用力点按取词", "翻译快捷键", "截图翻译快捷键",
                "翻译语言", "目标语言", "原文已是目标语言时译为",
                "翻译接口", "接口地址", "模型", "获取模型", "思考强度", "API Key", "测试连接",
            ]
        case .environment:
            ["辅助功能权限", "屏幕录制权限", "触控板设置", "查询与数据检测器", "用力点按和触感反馈"]
        }
        return names.map { String(localized: $0) }
    }

    /// 分类名或其中任一设置项名称包含 `query`（不区分大小写）即匹配；`query` 为空时匹配所有分类。
    func matches(_ query: String) -> Bool {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return true }
        return title.localizedCaseInsensitiveContains(query)
            || itemNames.contains { $0.localizedCaseInsensitiveContains(query) }
    }

    /// 按搜索词过滤后的分类，保持侧边栏原有顺序。
    static func filtered(by query: String) -> [SettingsCategory] {
        allCases.filter { $0.matches(query) }
    }
}
