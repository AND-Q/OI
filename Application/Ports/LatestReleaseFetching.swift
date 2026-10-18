import Foundation

/// 最新发布的版本（不含草稿与预发布版本）。
struct LatestRelease: Sendable, Equatable {
    /// 发布的标签，如 `v1.2.0`。
    let tagName: String
    /// 更新日志（Markdown），没有填写时为空字符串。
    let notes: String
    /// 发布页面，安装包在页面下方的附件中。
    let pageURL: URL
}

/// 查询最新发布版本的端口，用于检查更新。
protocol LatestReleaseFetching: Sendable {
    func fetchLatestRelease() async throws -> LatestRelease
}
