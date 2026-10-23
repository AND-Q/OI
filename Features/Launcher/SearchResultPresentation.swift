import Foundation

/// 启动器结果行的展示内容（副标题与 SF Symbols 图标），属于界面表现，不放在 Domain 模型中。
extension QuickQueryResult {
    var subtitle: String {
        switch self {
        case .calculation(let expression, _): return expression + " · 按回车复制"
        case .localIPAddress(let address):
            return address == nil ? "本机 IP · 当前不可用" : "本机 IP · 按回车复制"
        }
    }

    var symbolName: String {
        switch self {
        case .calculation: return "function"
        case .localIPAddress(let address): return address == nil ? "network.slash" : "network"
        }
    }
}

extension SearchResult {
    /// SF Symbol fallback for results without a file-system URL (quick queries and web URLs).
    var symbolName: String? {
        switch self {
        case .quickQuery(let result): return result.symbolName
        case .webURL: return "globe"
        case .application, .file: return nil
        }
    }
}
