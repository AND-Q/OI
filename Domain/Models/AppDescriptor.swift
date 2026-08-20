import Foundation

/// Platform-independent metadata discovered by the app catalog.
struct AppDescriptor: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let url: URL

    init(name: String, url: URL) {
        self.id = url.standardizedFileURL.path
        self.name = name
        self.url = url.standardizedFileURL
    }
}
