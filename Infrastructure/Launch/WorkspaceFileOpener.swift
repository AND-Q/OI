import AppKit

@MainActor
final class WorkspaceFileOpener: FileOpening {
    /// 文件夹没有系统登记的「打开方式」（Finder 右键菜单中也没有），补上这些常用编辑器中本机已安装的。
    private static let folderEditorBundleIdentifiers = [
        "com.microsoft.VSCode", // Visual Studio Code
        "com.todesktop.230313mzl4w4u92", // Cursor
        "com.exafunction.windsurf", // Windsurf
        "dev.zed.Zed", // Zed
        "com.sublimetext.4", // Sublime Text
        "com.apple.dt.Xcode", // Xcode
    ]

    func open(_ file: FileDescriptor) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            NSWorkspace.shared.open(
                file.url,
                configuration: NSWorkspace.OpenConfiguration()
            ) { @Sendable _, error in
                // 完成回调在后台队列执行：显式标为 @Sendable，Swift 6 下才不会被当作主线程闭包而在运行时断言失败。
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    func open(_ file: FileDescriptor, withApplicationAt applicationURL: URL) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            NSWorkspace.shared.open(
                [file.url],
                withApplicationAt: applicationURL,
                configuration: NSWorkspace.OpenConfiguration()
            ) { @Sendable _, error in
                // 完成回调在后台队列执行，标为 @Sendable 的原因同上。
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    /// 系统登记的能打开该文件的 App，与 Finder 右键「打开方式」一致；文件夹另补常用编辑器。
    /// 同一 App 装有多个副本时（如另存的旧版本）按 Bundle ID 只保留一个。
    func applications(toOpen file: FileDescriptor) -> [OpenWithApplication] {
        let workspace = NSWorkspace.shared
        let defaultApplication = workspace.urlForApplication(toOpen: file.url)
        var candidates = workspace.urlsForApplications(toOpen: file.url)
        if file.isDirectory {
            candidates += Self.folderEditorBundleIdentifiers.compactMap {
                workspace.urlForApplication(withBundleIdentifier: $0)
            }
        }
        var seenIdentifiers = Set<String>()
        let applications = ([defaultApplication].compactMap { $0 } + candidates)
            .filter { seenIdentifiers.insert(Bundle(url: $0)?.bundleIdentifier ?? $0.path).inserted }
            .map { url in
                OpenWithApplication(
                    url: url,
                    name: FileManager.default.displayName(atPath: url.path),
                    isDefault: url == defaultApplication
                )
            }
        return applications.sorted { lhs, rhs in
            if lhs.isDefault != rhs.isDefault { return lhs.isDefault }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    func revealInFinder(url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// 用系统终端打开目录，等价于 `open -a Terminal <目录>`。
    func openInTerminal(url: URL) {
        guard let terminalURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else { return }
        NSWorkspace.shared.open(
            [url],
            withApplicationAt: terminalURL,
            configuration: NSWorkspace.OpenConfiguration()
        )
    }
}
