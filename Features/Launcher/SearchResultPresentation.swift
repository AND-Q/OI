import Foundation

/// 启动器结果行的展示内容（副标题与 SF Symbols 图标），属于界面表现，不放在 Domain 模型中。
extension QuickQueryResult {
    var subtitle: String {
        switch self {
        case .calculation(let expression, _): expression + " · 按回车复制"
        case .localIPAddress(let address):
            address == nil ? "本机 IP · 当前不可用" : "本机 IP · 按回车复制"
        }
    }

    var symbolName: String {
        switch self {
        case .calculation: "function"
        case .localIPAddress(let address): address == nil ? "network.slash" : "network"
        }
    }
}

extension SearchResult {
    /// 没有文件地址的结果（快速查询与网址）使用的 SF Symbols 图标。
    var symbolName: String? {
        switch self {
        case .quickQuery(let result): result.symbolName
        case .webURL: "globe"
        case .application, .file: nil
        }
    }
}
