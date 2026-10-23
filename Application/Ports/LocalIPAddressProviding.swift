import Foundation

/// 读取本机局域网 IPv4 地址的端口，用于启动器的「本机 IP」快速查询。
protocol LocalIPAddressProviding: Sendable {
    /// 当前的局域网 IPv4 地址；没有可用的网络接口时为 nil。
    func currentIPv4Address() -> String?
}

/// 用作默认实现和测试用的固定地址实现；不读取网络接口。
struct MemoryLocalIPAddressProvider: LocalIPAddressProviding {
    let address: String?

    init(address: String? = nil) {
        self.address = address
    }

    func currentIPv4Address() -> String? {
        address
    }
}
