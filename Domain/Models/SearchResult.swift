import Foundation

/// 启动器的一行结果：来自应用目录、文件索引、快速查询或网址识别。
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

    /// 「在终端中打开」的目标目录：文件夹为其自身，文件与应用为其所在目录。
    var terminalDirectory: URL? {
        switch self {
        case .application(let app): return app.url.deletingLastPathComponent()
        case .file(let file): return file.isDirectory ? file.url : file.url.deletingLastPathComponent()
        case .quickQuery, .webURL: return nil
        }
    }
}
