import Foundation

/// 应用目录扫描发现的应用元数据，与具体平台无关。
struct AppDescriptor: Identifiable, Hashable, Sendable {
    /// 标准化后的安装路径，作为应用的唯一标识：
    /// 同一应用经符号链接等不同路径发现时，去重后仍是同一条目。
    let id: String
    let name: String
    /// 标准化后的 .app 包地址。
    let url: URL
    /// 应用的 Bundle Identifier（读取自 Info.plist），可能缺失。
    let bundleIdentifier: String?

    init(name: String, url: URL, bundleIdentifier: String? = nil) {
        self.id = url.standardizedFileURL.path
        self.name = name
        self.url = url.standardizedFileURL
        self.bundleIdentifier = bundleIdentifier
    }

    /// 使用历史的记录键：Bundle Identifier 在重装、移动后保持不变，
    /// 没有 Bundle Identifier 的应用退回用标准化路径作为键。
    var usageKey: String {
        bundleIdentifier ?? id
    }
}
