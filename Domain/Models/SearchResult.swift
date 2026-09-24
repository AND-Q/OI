import Foundation

/// A launcher result from the app catalog, file index or an immediate quick query.
enum SearchResult: Identifiable, Hashable, Sendable {
    case application(AppDescriptor)
    case file(FileDescriptor)
    case quickQuery(QuickQueryResult)

    var id: String {
        switch self {
        case .application(let app): return "app:" + app.id
        case .file(let file): return "file:" + file.id
        case .quickQuery(let result): return "quick:" + result.id
        }
    }

    var name: String {
        switch self {
        case .application(let app): return app.name
        case .file(let file): return file.name
        case .quickQuery(let result): return result.value
        }
    }

    var url: URL? {
        switch self {
        case .application(let app): return app.url
        case .file(let file): return file.url
        case .quickQuery: return nil
        }
    }

    var isQuickQuery: Bool {
        if case .quickQuery = self { return true }
        return false
    }
}
