import Carbon.HIToolbox
import Foundation

/// 可能因应用分发方式或测试环境而异的配置值。
struct AppConfiguration: Sendable {
    struct Shortcut: Sendable {
        let keyCode: UInt32
        let modifiers: UInt32
    }

    let applicationSearchDirectories: [URL]
    /// 以 bundle identifier 为键的内置别名覆盖（搜索计划 §7.1）。
    let applicationAliases: [String: [String]]
    let launcherShortcut: Shortcut

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
        launcherShortcut: Shortcut(
            keyCode: UInt32(kVK_Space),
            modifiers: UInt32(optionKey)
        )
    )
}
