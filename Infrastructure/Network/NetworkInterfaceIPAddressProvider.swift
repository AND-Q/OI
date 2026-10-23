import Darwin

/// 经 `getifaddrs` 读取本机局域网 IPv4 地址：只看已启用、非回环的网络接口，跳过 VPN、隔空投送等虚拟接口与
/// 链路本地地址（169.254/16），有多个时优先 en0，其次其他以太网与 Wi-Fi 接口。
struct NetworkInterfaceIPAddressProvider: LocalIPAddressProviding {
    func currentIPv4Address() -> String? {
        var interfaceList: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaceList) == 0, let firstInterface = interfaceList else { return nil }
        defer { freeifaddrs(firstInterface) }

        var candidates: [(priority: Int, address: String)] = []
        var currentInterface: UnsafeMutablePointer<ifaddrs>? = firstInterface

        while let interface = currentInterface {
            let details = interface.pointee
            currentInterface = details.ifa_next

            guard let address = details.ifa_addr,
                  address.pointee.sa_family == sa_family_t(AF_INET),
                  details.ifa_flags & UInt32(IFF_UP) != 0,
                  details.ifa_flags & UInt32(IFF_RUNNING) != 0,
                  details.ifa_flags & UInt32(IFF_LOOPBACK) == 0 else { continue }

            let name = String(cString: details.ifa_name)
            guard !["utun", "awdl", "llw", "bridge", "gif", "stf", "lo"]
                .contains(where: { name.hasPrefix($0) }) else { continue }

            let socketAddress = UnsafeRawPointer(address)
                .assumingMemoryBound(to: sockaddr_in.self)
                .pointee
            let octets = withUnsafeBytes(of: socketAddress.sin_addr.s_addr) { Array($0) }
            guard octets.count == 4, octets[0] != 169 || octets[1] != 254 else { continue }
            guard octets.contains(where: { $0 != 0 }) else { continue }

            let addressString = octets.map(String.init).joined(separator: ".")
            let priority = name == "en0" ? 0 : (name.hasPrefix("en") ? 1 : 2)
            candidates.append((priority, addressString))
        }

        return candidates.min { $0.priority < $1.priority }?.address
    }
}
