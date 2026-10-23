import CoreServices
import Foundation
import os

/// 基于系统 Spotlight 索引（`MDQuery`）的文件与文件夹搜索。
/// 每次查询在后台线程同步执行一次静态查询（不订阅实时更新）。
/// 用 `MDQuery` 而非 `NSMetadataQuery`：排序键与所需属性随查询一并预取，
/// 逐条读取几乎零开销，且不占用主线程。
struct SpotlightFileSearcher: FileSearching {
    /// 粗排键：打开过的文件按打开时间靠前，其余按修改时间；两者都降序。
    /// 只用打开时间会让从未打开的文件顺序随机，只用修改时间会把最近打开过的挤掉。
    /// 存为 `String` 而非 `CFString`，后者不是 `Sendable`。
    private static let sortingAttributes: [String] = [
        kMDItemLastUsedDate as String,
        kMDItemContentModificationDate as String,
    ]
    /// 随查询预取的属性；路径不在其列，需从 `MDItem` 单独读取。
    private static let valueAttributes: [String] = [
        kMDItemDisplayName as String,
        kMDItemContentType as String,
        kMDItemLastUsedDate as String,
        kMDItemContentModificationDate as String,
        kMDItemDateAdded as String,
    ]
    /// 串行执行，避免连续输入时多个查询同时压在 mds 上。
    private static let queue = DispatchQueue(label: "oi.spotlight-file-search", qos: .userInitiated)

    private let homeDirectory: URL

    init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.homeDirectory = homeDirectory.standardizedFileURL
    }

    func search(query: String, limit: Int) async throws -> [FileDescriptor] {
        let queryString = Self.queryString(for: query)
        let excludedDirectories = Self.excludedDirectories(homeDirectory: homeDirectory)
        let includedDirectories = Self.includedDirectories(homeDirectory: homeDirectory)
        // 同步查询一旦开始就无法中途停止；排队期间已被新输入取代的查询直接跳过，
        // 最新查询至多等正在执行的那一次，而不是等过期查询依次跑完。
        let isCancelled = OSAllocatedUnfairLock(initialState: false)
        try Task.checkCancellation()
        let files: [FileDescriptor] = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                Self.queue.async {
                    continuation.resume(with: Result {
                        guard !isCancelled.withLock({ $0 }) else { throw CancellationError() }
                        return try Self.execute(
                            queryString,
                            excludedDirectories: excludedDirectories,
                            includedDirectories: includedDirectories,
                            limit: limit
                        )
                    })
                }
            }
        } onCancel: {
            isCancelled.withLock { $0 = true }
        }
        try Task.checkCancellation()
        return files
    }

    /// 未获「文件与文件夹」授权时，mds 会静默剔除桌面、文稿、下载目录下的结果，
    /// 而系统只在 App 实际读取这些目录时才弹出授权窗，所以各列一次目录来触发。
    /// 授权窗会阻塞发起读取的线程，故放到后台执行；TCC 会记住结果，之后不再弹。
    func requestProtectedFolderAccess() {
        let folders = ["Desktop", "Documents", "Downloads"].map {
            homeDirectory.appendingPathComponent($0, isDirectory: true)
        }
        Task.detached(priority: .utility) {
            for folder in folders {
                _ = try? FileManager.default.contentsOfDirectory(atPath: folder.path)
            }
        }
    }

    /// 与原生 Spotlight 一致的按词前缀匹配（`cdw`：忽略大小写、音调，按单词边界），
    /// 并排除 `.app` 以免与应用分组重复。
    static func queryString(for query: String) -> String {
        "kMDItemDisplayName == \"\(escape(query))*\"cdw"
            + " && kMDItemContentTypeTree != \"com.apple.application-bundle\""
    }

    /// 元数据查询串中 `\`、`"` 以及通配符 `*`、`?` 需要用反斜杠转义。
    static func escape(_ text: String) -> String {
        var escaped = ""
        for character in text {
            if ["\\", "\"", "*", "?"].contains(character) {
                escaped.append("\\")
            }
            escaped.append(character)
        }
        return escaped
    }

    /// `~/Library` 中几乎全是缓存与支持文件，只会淹没真正的用户文件。
    static func excludedDirectories(homeDirectory: URL) -> [URL] {
        [homeDirectory.appendingPathComponent("Library", isDirectory: true)]
    }

    /// 排除目录中仍然保留的子目录：iCloud 云盘的本地文件（云盘根目录与 Pages、Numbers 等 App 的文件夹）
    /// 存放在 `~/Library/Mobile Documents` 下，原生 Spotlight 同样能搜到。
    static func includedDirectories(homeDirectory: URL) -> [URL] {
        [homeDirectory.appendingPathComponent("Library/Mobile Documents", isDirectory: true)]
    }

    /// 过滤排除目录下（保留的子目录除外）的条目以及路径中含隐藏分量的条目。
    static func isVisible(path: String, excludedDirectories: [URL], includedDirectories: [URL]) -> Bool {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        if !includedDirectories.contains(where: { isPath(url.path, inside: $0) }),
           excludedDirectories.contains(where: { isPath(url.path, inside: $0) }) {
            return false
        }
        return !url.pathComponents.dropFirst().contains { $0.hasPrefix(".") }
    }

    private static func isPath(_ path: String, inside directory: URL) -> Bool {
        let prefix = directory.path.hasSuffix("/") ? directory.path : directory.path + "/"
        return path.hasPrefix(prefix)
    }

    /// 同步执行查询并按粗排顺序转换前 `limit` 条可见结果。
    private static func execute(
        _ queryString: String,
        excludedDirectories: [URL],
        includedDirectories: [URL],
        limit: Int
    ) throws -> [FileDescriptor] {
        guard let query = MDQueryCreate(
            kCFAllocatorDefault,
            queryString as CFString,
            valueAttributes as CFArray,
            sortingAttributes as CFArray
        ) else {
            throw SpotlightQueryError.startFailed
        }
        MDQuerySetSearchScope(query, [kMDQueryScopeHome] as CFArray, 0)
        for attribute in sortingAttributes {
            MDQuerySetSortOptionFlagsForAttribute(
                query, attribute as CFString, UInt32(kMDQueryReverseSortOrderFlag.rawValue)
            )
        }
        guard MDQueryExecute(query, CFOptionFlags(kMDQuerySynchronous.rawValue)) else {
            throw SpotlightQueryError.startFailed
        }

        var files: [FileDescriptor] = []
        for index in 0..<MDQueryGetResultCount(query) {
            guard files.count < limit else { break }
            guard let result = MDQueryGetResultAtIndex(query, index) else { continue }
            let item = Unmanaged<MDItem>.fromOpaque(result).takeUnretainedValue()
            guard let path = MDItemCopyAttribute(item, kMDItemPath) as? String,
                  isVisible(path: path, excludedDirectories: excludedDirectories, includedDirectories: includedDirectories)
            else { continue }
            let url = URL(fileURLWithPath: path)
            files.append(FileDescriptor(
                name: value(kMDItemDisplayName, of: query, at: index) as? String ?? url.lastPathComponent,
                url: url,
                isDirectory: value(kMDItemContentType, of: query, at: index) as? String == "public.folder",
                activityDate: activityDate(of: query, at: index)
            ))
        }
        return files
    }

    /// 打开、修改、加入目录三者中最新的时间；`kMDItemDateAdded` 覆盖下载与拖入保存。
    private static func activityDate(of query: MDQuery, at index: CFIndex) -> Date {
        [kMDItemLastUsedDate, kMDItemContentModificationDate, kMDItemDateAdded]
            .compactMap { value($0, of: query, at: index) as? Date }
            .max() ?? .distantPast
    }

    /// 读取随查询预取的属性值（仅限 `valueAttributes` 与 `sortingAttributes`）。
    private static func value(_ attribute: CFString, of query: MDQuery, at index: CFIndex) -> Any? {
        guard let pointer = MDQueryGetAttributeValueOfResultAtIndex(query, attribute, index) else {
            return nil
        }
        return Unmanaged<AnyObject>.fromOpaque(pointer).takeUnretainedValue()
    }
}

private enum SpotlightQueryError: LocalizedError {
    case startFailed

    var errorDescription: String? {
        String(localized: "无法启动 Spotlight 查询")
    }
}
