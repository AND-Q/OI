import Foundation

/// 结构化比较键（搜索计划 §8.2）：先比匹配层级，再比文本质量，
/// 最后比使用信号。使用信号永远不会跨越层级生效。
struct MatchScore: Comparable, Sendable {
    let tier: Int
    let textScore: Int
    let recencyScore: Int
    let usageScore: Int

    static func < (lhs: MatchScore, rhs: MatchScore) -> Bool {
        if lhs.tier != rhs.tier { return lhs.tier < rhs.tier }
        if lhs.textScore != rhs.textScore { return lhs.textScore < rhs.textScore }
        if lhs.recencyScore != rhs.recencyScore { return lhs.recencyScore < rhs.recencyScore }
        // 启动次数越多分数越大，但排位越靠前，因此用降序。
        return lhs.usageScore > rhs.usageScore
    }
}

/// 基于不可变应用快照的内存分层匹配器（搜索计划 §8）。
/// 搜索从不触碰磁盘；使用记录在每次查询时传入。
struct ApplicationSearchIndex: Sendable {
    static let maximumQueryLength = 64
    static let resultLimit = 50

    private let documents: [ApplicationSearchDocument]

    init(applications: [AppDescriptor] = [], aliases: [String: [String]] = [:]) {
        self.documents = applications
            .map { ApplicationSearchDocument(app: $0, aliases: aliases[$0.bundleIdentifier ?? ""] ?? []) }
            .sorted { $0.app.name.localizedStandardCompare($1.app.name) == .orderedAscending }
    }

    func search(
        query: String,
        usage: [String: AppUsageRecord] = [:],
        now: Date = Date()
    ) -> [AppDescriptor] {
        let normalizedQuery = SearchTextNormalizer.normalize(query)
        guard !normalizedQuery.isEmpty, normalizedQuery.count <= Self.maximumQueryLength else {
            return []
        }

        var matches: [(document: ApplicationSearchDocument, score: MatchScore)] = []
        for document in documents {
            if let score = matchScore(for: document, query: normalizedQuery, usage: usage, now: now) {
                matches.append((document, score))
            }
        }

        matches.sort { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score < rhs.score }
            return lhs.document.app.name.localizedStandardCompare(rhs.document.app.name) == .orderedAscending
        }

        return matches.prefix(Self.resultLimit).map { $0.document.app }
    }

    private func matchScore(
        for document: ApplicationSearchDocument,
        query: String,
        usage: [String: AppUsageRecord],
        now: Date
    ) -> MatchScore? {
        let tier: Int
        let textScore: Int

        if document.normalizedName == query {
            tier = 0
            textScore = 0
        } else if document.normalizedName.hasPrefix(query) {
            tier = 1
            textScore = 0
        } else if document.nameTokens.contains(where: { $0.hasPrefix(query) }) {
            tier = 2
            textScore = 0
        } else if let position = secondaryFieldPosition(document, query: query) {
            tier = 3
            textScore = position
        } else if document.aliases.contains(where: { $0.hasPrefix(query) || $0.contains(query) })
            || document.initials.hasPrefix(query) {
            tier = 4
            textScore = 0
        } else if let position = pinyinPosition(document, query: query) {
            tier = 5
            textScore = position
        } else if let range = document.normalizedName.range(of: query) {
            tier = 6
            textScore = document.normalizedName.distance(
                from: document.normalizedName.startIndex,
                to: range.lowerBound
            )
        } else if let gaps = fuzzyGapCount(document.normalizedName, query: query) {
            tier = 7
            textScore = gaps
        } else {
            return nil
        }

        let record = usage[document.app.usageKey]
        return MatchScore(
            tier: tier,
            textScore: textScore,
            recencyScore: recencyScore(for: record, now: now),
            usageScore: usageScore(for: record)
        )
    }

    /// 在 bundle 文件名与去掉「顶级域.厂商」的 bundle identifier 上计算前缀或包含位置，
    /// 完整 bundle identifier 只做前缀匹配；前缀命中凭借更小的位置值优先于更靠后的包含命中。
    private func secondaryFieldPosition(
        _ document: ApplicationSearchDocument,
        query: String
    ) -> Int? {
        // 直接输入 `com.microsoft…` 时按完整 ID 前缀命中；只输入顶级域段（`co`、`com`）不算。
        if query.count > document.bundleIdentifierDomainLength,
           document.normalizedBundleIdentifier.hasPrefix(query) {
            return 0
        }
        var best: Int?
        for field in [document.normalizedBundleName, document.normalizedBundleIdentifierProduct]
        where !field.isEmpty {
            let position: Int
            if field.hasPrefix(query) {
                position = 0
            } else if let range = field.range(of: query) {
                position = field.distance(from: field.startIndex, to: range.lowerBound)
            } else {
                continue
            }
            if position < best ?? Int.max {
                best = position
            }
        }
        return best
    }

    /// 全拼从名字中某个字开始以查询为前缀时，返回该字在全拼中的位置；
    /// 从开头匹配为 0，凭借更小的位置值优先于从中间某个字开始的匹配。
    private func pinyinPosition(
        _ document: ApplicationSearchDocument,
        query: String
    ) -> Int? {
        document.pinyinSuffixes
            .first { $0.hasPrefix(query) }
            .map { document.pinyin.count - $0.count }
    }

    /// 子序列匹配代价：沿名称行走时跳过的字符总数。
    private func fuzzyGapCount(_ name: String, query: String) -> Int? {
        let nameChars = Array(name)
        var nameIndex = 0
        var skipped = 0

        for queryChar in query {
            var found = false
            while nameIndex < nameChars.count {
                if nameChars[nameIndex] == queryChar {
                    nameIndex += 1
                    found = true
                    break
                }
                nameIndex += 1
                skipped += 1
            }
            guard found else { return nil }
        }

        return skipped
    }

    /// 距上次启动的天数，上限 30；从未启动过的排在最后。
    private func recencyScore(for record: AppUsageRecord?, now: Date) -> Int {
        guard let lastLaunchedAt = record?.lastLaunchedAt else { return 30 }
        let days = Int(now.timeIntervalSince(lastLaunchedAt) / 86_400)
        return min(30, max(0, days))
    }

    /// 对启动次数取对数缩放，避免原始次数在同级内占主导。
    private func usageScore(for record: AppUsageRecord?) -> Int {
        guard let launchCount = record?.launchCount, launchCount > 0 else { return 0 }
        return Int(log2(Double(1 + launchCount)))
    }
}
