import Foundation

/// 用点分隔的版本号（如 `1.2.0`），用于比较当前运行的版本与 GitHub 上最新发布的版本。
/// 允许 `v` 前缀（Release 标签写作 `v1.2.0`）；比较时缺少的段按 0 处理（`1.2` 与 `1.2.0` 相同）。
struct AppVersion: Comparable, Sendable, CustomStringConvertible {
    let components: [Int]

    /// 每一段都必须是数字，否则返回 nil（如 `1.2.0-beta`、`nightly`）。
    init?(_ string: String) {
        var text = Substring(string.trimmingCharacters(in: .whitespacesAndNewlines))
        if text.first == "v" || text.first == "V" {
            text = text.dropFirst()
        }
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        let numbers = parts.compactMap { part in
            part.allSatisfy { $0.isASCII && $0.isNumber } ? Int(part) : nil
        }
        guard !parts.isEmpty, numbers.count == parts.count else { return nil }
        components = numbers
    }

    var description: String {
        components.map(String.init).joined(separator: ".")
    }

    static func == (lhs: AppVersion, rhs: AppVersion) -> Bool {
        !(lhs < rhs) && !(rhs < lhs)
    }

    static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        for index in 0..<max(lhs.components.count, rhs.components.count) {
            let left = index < lhs.components.count ? lhs.components[index] : 0
            let right = index < rhs.components.count ? rhs.components[index] : 0
            if left != right {
                return left < right
            }
        }
        return false
    }
}
