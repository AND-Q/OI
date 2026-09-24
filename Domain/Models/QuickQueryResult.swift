import Foundation

/// A temporary value produced directly from the launcher's search query.
enum QuickQueryResult: Hashable, Sendable {
    case calculation(expression: String, value: String)
    case localIPAddress(String?)

    var id: String {
        switch self {
        case .calculation(let expression, _): return "calculation:" + expression
        case .localIPAddress: return "local-ip-address"
        }
    }

    var value: String {
        switch self {
        case .calculation(_, let value): return value
        case .localIPAddress(let address): return address ?? "未获取到局域网 IPv4 地址"
        }
    }

    var subtitle: String {
        switch self {
        case .calculation(let expression, _): return expression + " · 按回车复制"
        case .localIPAddress(let address):
            return address == nil ? "本机 IP · 当前不可用" : "本机 IP · 按回车复制"
        }
    }

    var copyValue: String? {
        switch self {
        case .calculation(_, let value): return value
        case .localIPAddress(let address): return address
        }
    }

    var symbolName: String {
        switch self {
        case .calculation: return "function"
        case .localIPAddress(let address): return address == nil ? "network.slash" : "network"
        }
    }
}
