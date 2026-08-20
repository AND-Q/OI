import AppKit

@MainActor
final class WorkspaceApplicationIconProvider: ApplicationIconProviding {
    private var cache: [URL: NSImage] = [:]

    func icon(for url: URL) -> NSImage {
        let normalizedURL = url.standardizedFileURL
        if let cachedIcon = cache[normalizedURL] {
            return cachedIcon
        }

        let icon = NSWorkspace.shared.icon(forFile: normalizedURL.path)
        cache[normalizedURL] = icon
        return icon
    }
}
