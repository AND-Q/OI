import AppKit

@MainActor
final class WorkspaceIconProvider: IconProviding {
    /// 文件结果的地址数量没有上限；缓存超过这个数量时整体清空。
    static let cacheLimit = 500

    private var cache: [URL: NSImage] = [:]

    func icon(for url: URL) -> NSImage {
        let normalizedURL = url.standardizedFileURL
        if let cachedIcon = cache[normalizedURL] {
            return cachedIcon
        }

        if cache.count >= Self.cacheLimit {
            cache.removeAll(keepingCapacity: true)
        }
        let icon = NSWorkspace.shared.icon(forFile: normalizedURL.path)
        cache[normalizedURL] = icon
        return icon
    }
}
