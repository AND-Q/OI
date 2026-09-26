import Foundation

/// A launcher result from the app catalog, file index or an immediate quick query.
enum SearchResult: Identifiable, Hashable, Sendable {
    case application(AppDescriptor)
    case file(FileDescriptor)
    case quickQuery(QuickQueryResult)
    case webURL(URL)

    var id: String {
        switch self {
        case .application(let app): return "app:" + app.id
        case .file(let file): return "file:" + file.id
        case .quickQuery(let result): return "quick:" + result.id
        case .webURL(let url): return "web-url:" + url.absoluteString
        }
    }

    var name: String {
        switch self {
        case .application(let app): return app.name
        case .file(let file): return file.name
        case .quickQuery(let result): return result.value
        case .webURL(let url): return url.absoluteString
        }
    }

    var url: URL? {
        switch self {
        case .application(let app): return app.url
        case .file(let file): return file.url
        case .quickQuery: return nil
        case .webURL(let url): return url
        }
    }

    var isQuickQuery: Bool {
        if case .quickQuery = self { return true }
        return false
    }

    /// SF Symbol fallback for results without a file-system URL (quick queries and web URLs).
    var symbolName: String? {
        switch self {
        case .quickQuery(let result): return result.symbolName
        case .webURL: return "globe"
        case .application, .file: return nil
        }
    }
}
