import AppKit

@MainActor
final class WorkspaceIconProvider: IconProviding {
    /// File results can produce unbounded distinct URLs; drop the cache once it grows past this.
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
