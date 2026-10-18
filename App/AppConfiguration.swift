import Foundation

/// 可能因应用分发方式或测试环境而异的配置值。
struct AppConfiguration: Sendable {
    let applicationSearchDirectories: [URL]
    /// 以 bundle identifier 为键的内置别名覆盖（搜索计划 §7.1）。
    let applicationAliases: [String: [String]]
    /// 文件分组最多展示的条数。
    let fileSearchResultLimit: Int
    /// 触发文件搜索所需的最少查询字符数，过短的查询只会返回噪音。
    let fileSearchMinimumQueryLength: Int
    /// 检查更新查询的 GitHub 仓库（`所有者/仓库名`），即发布安装包的仓库。
    let releaseRepository: String

    static let live = AppConfiguration(
        applicationSearchDirectories: [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Cryptexes/App/System/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Library/CoreServices/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app", isDirectory: true),
            URL(
                fileURLWithPath: "/System/Library/CoreServices/Finder.app/Contents/Applications",
                isDirectory: true
            ),
        ],
        applicationAliases: [
            "com.microsoft.VSCode": ["vscode"],
        ],
        fileSearchResultLimit: 100,
        fileSearchMinimumQueryLength: 2,
        releaseRepository: "AND-Q/OI"
    )
}
