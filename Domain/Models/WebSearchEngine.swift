import Foundation

/// `⌘↩` 网页搜索使用的搜索引擎。`rawValue` 用于持久化。
enum WebSearchEngine: String, CaseIterable, Identifiable, Sendable {
    case bing
    case google
    case baidu
    case duckDuckGo = "duckduckgo"

    var id: String { rawValue }

    /// 设置面板中展示的名称。
    var displayName: String {
        switch self {
        case .bing: "必应"
        case .google: "Google"
        case .baidu: "百度"
        case .duckDuckGo: "DuckDuckGo"
        }
    }

    /// 在默认浏览器中打开的搜索地址，查询内容按 URL 规则编码。
    func searchURL(for query: String) -> URL? {
        let endpoint: (address: String, queryName: String) = switch self {
        case .bing: ("https://www.bing.com/search", "q")
        case .google: ("https://www.google.com/search", "q")
        case .baidu: ("https://www.baidu.com/s", "wd")
        case .duckDuckGo: ("https://duckduckgo.com/", "q")
        }
        var components = URLComponents(string: endpoint.address)
        components?.queryItems = [URLQueryItem(name: endpoint.queryName, value: query)]
        return components?.url
    }
}
