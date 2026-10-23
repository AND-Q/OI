import AppKit
import os

@MainActor
final class WorkspaceFileOpener: FileOpening {
    /// 路径直达查看文件系统的串行队列：路径落在无响应的网络卷上时一次查看可能阻塞数秒，串行执行使连续输入
    /// 至多占住一个线程；排队期间已被新输入取代的查看直接跳过，最新的输入至多等正在执行的那一次。
    private nonisolated static let itemLookupQueue = DispatchQueue(label: "oi.path-item-lookup", qos: .userInitiated)

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

    /// 按路径直接查看文件系统，路径中的符号链接照常跟随。文件夹按文件夹处理（Enter 在 Finder 中打开），
    /// App 等文件包按文件处理（Enter 与在 Finder 中双击一样，App 即启动）。展开后不是绝对路径（如 `~不存在的用户`）时为 nil。
    /// 在串行队列上查看，不占用主线程；排队期间任务已取消时直接返回 nil。
    func item(atPath path: String) async -> FileDescriptor? {
        let isCancelled = OSAllocatedUnfairLock(initialState: false)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<FileDescriptor?, Never>) in
                // 在后台队列执行：显式标为 @Sendable，Swift 6 下才不会被当作主线程闭包而在运行时断言失败。
                Self.itemLookupQueue.async { @Sendable in
                    let isSuperseded = isCancelled.withLock { $0 }
                    continuation.resume(returning: isSuperseded ? nil : Self.lookUpItem(atPath: path))
                }
            }
        } onCancel: {
            isCancelled.withLock { $0 = true }
        }
    }

    /// 只用 Foundation 查看文件系统，可在后台线程执行；文件包按资源属性判断，不依赖 AppKit。
    private nonisolated static func lookUpItem(atPath path: String) -> FileDescriptor? {
        let expandedPath = (path as NSString).expandingTildeInPath
        var isDirectory: ObjCBool = false
        guard expandedPath.hasPrefix("/"),
              FileManager.default.fileExists(atPath: expandedPath, isDirectory: &isDirectory) else { return nil }
        let url = URL(fileURLWithPath: expandedPath, isDirectory: isDirectory.boolValue)
        let isPackage = (try? url.resourceValues(forKeys: [.isPackageKey]))?.isPackage == true
        return FileDescriptor(
            name: FileManager.default.displayName(atPath: expandedPath),
            url: url,
            isDirectory: isDirectory.boolValue && !isPackage
        )
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
