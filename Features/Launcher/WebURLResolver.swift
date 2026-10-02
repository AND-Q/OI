import Foundation

/// 识别输入框中的网址与 localhost，并构造默认浏览器的搜索地址。
enum WebURLResolver {
    /// 识别可直达打开的网址：显式 scheme、常见顶级域域名，或 localhost / 127.0.0.1（可含端口与路径）。
    static func recognize(_ query: String) -> URL? {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        // 含内部空格的是搜索短语，不是网址。
        guard !trimmedQuery.isEmpty,
              !trimmedQuery.contains(where: \.isWhitespace) else {
            return nil
        }

        // `example.com:8080` 会被 Foundation 解析出伪 scheme，因此非网页 scheme 一律回落到补全分支。
        if let url = URL(string: trimmedQuery),
           let scheme = url.scheme?.lowercased(),
           ["http", "https", "ftp"].contains(scheme),
           let host = url.host, !host.isEmpty {
            return url
        }
        return recognizeSchemeless(trimmedQuery)
    }

    /// 构造默认浏览器的搜索地址。
    static func searchURL(for query: String) -> URL? {
        var components = URLComponents(string: "https://www.bing.com/search")
        components?.queryItems = [URLQueryItem(name: "q", value: query)]
        return components?.url
    }

    /// 无 scheme 的输入补全 `https://`（localhost / 127.0.0.1 补 `http://`，适配纯 http 的本地
    /// 开发服务器）后校验主机：仅接受 localhost 与常见顶级域，
    /// 避免把 `photo.png`、`report.pdf` 等文件名、算式或 IP 片段误判为网址。
    private static func recognizeSchemeless(_ trimmedQuery: String) -> URL? {
        // 含 @ 的输入（如邮箱）不属于裸域名。
        guard !trimmedQuery.contains("@"),
              let url = URL(string: "https://" + trimmedQuery),
              let host = url.host?.lowercased() else { return nil }

        if host == "localhost" || host == "127.0.0.1" {
            return URL(string: "http://" + trimmedQuery)
        }

        // 裸域名必须是 domain.tld 形式：单标签词（app、tv、ai）留给应用搜索，
        // 空标签段（example..com）是畸形输入。
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2,
              !parts.contains(where: \.isEmpty),
              let tld = parts.last,
              knownTLDs.contains(String(tld)) else { return nil }
        // 与常见文件扩展名同形的顶级域：裸「名称.后缀」更可能是在找文件（Xcode.app、install.sh），
        // 带 www.、端口、路径或查询参数时才按网址识别。
        if fileExtensionLikeTLDs.contains(String(tld)),
           !host.hasPrefix("www."), url.port == nil, url.path().isEmpty, url.query() == nil {
            return nil
        }
        return url
    }

    /// 与常见文件扩展名同形的顶级域（应用包、Illustrator、Shell 脚本、C++ 源码、动态库）。
    private static let fileExtensionLikeTLDs: Set<String> = ["app", "ai", "sh", "cc", "so"]

    private static let knownTLDs: Set<String> = [
        "com", "org", "net", "edu", "gov", "int", "mil",
        "io", "ai", "co", "dev", "app", "me", "info", "xyz", "top", "cc", "tv",
        "cn", "hk", "tw", "mo", "jp", "kr", "sg", "in", "my", "th", "vn", "id", "ph", "au", "nz",
        "us", "ca", "mx", "br", "ar", "cl",
        "uk", "ie", "de", "fr", "es", "pt", "it", "nl", "be", "ch", "at", "se", "no", "fi", "dk",
        "pl", "cz", "sk", "hu", "ro", "bg", "gr", "ru", "ua", "tr", "il", "ae", "sa", "za",
        "gg", "gl", "fm", "sh", "to", "ly", "so", "nu", "is"
    ]
}
