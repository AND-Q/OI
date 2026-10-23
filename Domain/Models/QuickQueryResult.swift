import Foundation

/// 由启动器输入直接算出的临时结果（计算、本机 IP）。
enum QuickQueryResult: Hashable, Sendable {
    case calculation(expression: String, value: String)
    case localIPAddress(String?)

    var id: String {
        switch self {
        case .calculation(let expression, _): "calculation:" + expression
        case .localIPAddress: "local-ip-address"
        }
    }

    var value: String {
        switch self {
        case .calculation(_, let value): value
        case .localIPAddress(let address): address ?? "未获取到局域网 IPv4 地址"
        }
    }

    var copyValue: String? {
        switch self {
        case .calculation(_, let value): value
        case .localIPAddress(let address): address
        }
    }
}
