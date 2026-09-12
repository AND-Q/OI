import Foundation

/// Platform-independent metadata discovered by the app catalog.
struct AppDescriptor: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let url: URL
    let bundleIdentifier: String?

    init(name: String, url: URL, bundleIdentifier: String? = nil) {
        self.id = url.standardizedFileURL.path
        self.name = name
        self.url = url.standardizedFileURL
        self.bundleIdentifier = bundleIdentifier
    }

    /// Usage-history key: the bundle identifier survives reinstalls and moves,
    /// the standardized path is the fallback when the bundle has none.
    var usageKey: String {
        bundleIdentifier ?? id
    }
}
