import Foundation

/// 查询文件索引并做轻量二次排序。Spotlight 已按词前缀过滤，这里只把
/// 显示名完全匹配和名称前缀匹配提到前面，同级保留索引返回的顺序。
/// 先取一批较大的候选再排序、再截断到展示条数，否则完全匹配的文件
/// 只要不在最近使用的前几条里就会在排序前被丢掉。
struct SearchFiles: Sendable {
    /// 从索引拉取的候选上限：属性随查询预取、逐条转换几乎零开销，
    /// 上限只是对极宽泛查询（如 `a*`）的保护。
    static let candidateLimit = 2000

    private let searcher: any FileSearching
    private let limit: Int

    init(searcher: any FileSearching, limit: Int) {
        self.searcher = searcher
        self.limit = limit
    }

    func execute(query: String) async throws -> [FileDescriptor] {
        let files: [FileDescriptor]
        do {
            files = try await searcher.search(query: query, limit: Self.candidateLimit)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ApplicationError.fileSearchFailed(reason: error.localizedDescription)
        }
        return Array(FileResultRanker.rank(files, query: query).prefix(limit))
    }
}

enum FileResultRanker {
    /// 去掉扩展名后的显示名完全匹配 > 名称前缀 > 其他；同级按活跃时间降序，再按输入顺序稳定。
    static func rank(_ files: [FileDescriptor], query: String) -> [FileDescriptor] {
        let normalizedQuery = normalize(query)
        guard !normalizedQuery.isEmpty else { return files }

        return files.enumerated()
            .map { offset, file -> (tier: Int, offset: Int, file: FileDescriptor) in
                let name = normalize(file.name)
                let stem = normalize((file.name as NSString).deletingPathExtension)
                let tier: Int
                if name == normalizedQuery || stem == normalizedQuery {
                    tier = 0
                } else if name.hasPrefix(normalizedQuery) {
                    tier = 1
                } else {
                    tier = 2
                }
                return (tier, offset, file)
            }
            .sorted { lhs, rhs in
                if lhs.tier != rhs.tier { return lhs.tier < rhs.tier }
                if lhs.file.activityDate != rhs.file.activityDate {
                    return lhs.file.activityDate > rhs.file.activityDate
                }
                return lhs.offset < rhs.offset
            }
            .map(\.file)
    }

    private static func normalize(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }
}
