import Foundation

/// A single launcher result: applications come from the in-memory catalog,
/// files and folders from the system file index.
enum SearchResult: Identifiable, Hashable, Sendable {
    case application(AppDescriptor)
    case file(FileDescriptor)

    var id: String {
        switch self {
        case .application(let app): return "app:" + app.id
        case .file(let file): return "file:" + file.id
        }
    }

    var name: String {
        switch self {
        case .application(let app): return app.name
        case .file(let file): return file.name
        }
    }

    var url: URL {
        switch self {
        case .application(let app): return app.url
        case .file(let file): return file.url
        }
    }
}
