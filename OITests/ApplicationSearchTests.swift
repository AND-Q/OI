import Foundation
import XCTest

@testable import OI

@MainActor
final class ApplicationSearchTests: XCTestCase {
    // MARK: 标准化

    func testNormalizeMergesSeparatorsAndIgnoresCaseAndDiacritics() {
        XCTAssertEqual(SearchTextNormalizer.normalize("Visual Studio Code"), "visualstudiocode")
        XCTAssertEqual(SearchTextNormalizer.normalize("Café  Bar"), "cafebar")
        XCTAssertEqual(SearchTextNormalizer.normalize("  A_-B "), "ab")
    }

    func testTokenizeSplitsOnSeparators() {
        XCTAssertEqual(SearchTextNormalizer.tokenize("Visual Studio Code"), ["visual", "studio", "code"])
        XCTAssertEqual(SearchTextNormalizer.tokenize(" -_ "), [])
    }

    func testPinyinTransliteratesChineseAndSkipsLatin() {
        XCTAssertEqual(SearchTextNormalizer.pinyin(of: "微信"), "weixin")
        XCTAssertEqual(SearchTextNormalizer.pinyin(of: "QQ音乐"), "qqyinle")
        XCTAssertEqual(SearchTextNormalizer.pinyin(of: "剪映-专业版"), "jianyingzhuanyeban")
        XCTAssertEqual(SearchTextNormalizer.pinyin(of: "Safari"), "")
    }

    func testInitialsCoverLatinAndChinese() {
        XCTAssertEqual(SearchTextNormalizer.initials(of: "Visual Studio Code"), "vsc")
        XCTAssertEqual(SearchTextNormalizer.initials(of: "微信"), "wx")
        XCTAssertEqual(SearchTextNormalizer.initials(of: "剪映-专业版"), "jyzyb")
        XCTAssertEqual(SearchTextNormalizer.initials(of: "Visual-Studio-Code"), "vsc")
    }

    /// 回归测试：混合中英文名的拼音全拼、连字符名称的拼音/首字母都能命中（文档 §7.2）。
    func testPinyinAndInitialsMatchForMixedAndHyphenatedNames() {
        let index = makeIndex(["QQ音乐", "剪映-专业版", "Visual-Studio-Code"])
        XCTAssertEqual(index.search(query: "qqyinle").map(\.name), ["QQ音乐"])
        XCTAssertEqual(index.search(query: "jianyingzhuan").map(\.name), ["剪映-专业版"])
        XCTAssertEqual(index.search(query: "jyzyb").map(\.name), ["剪映-专业版"])
    }

    // MARK: 匹配等级

    private func makeIndex(
        _ names: [String],
        bundleIdentifiers: [String] = [],
        aliases: [String: [String]] = [:]
    ) -> ApplicationSearchIndex {
        let applications = names.enumerated().map { index, name in
            AppDescriptor(
                name: name,
                url: URL(fileURLWithPath: "/Applications/\(name).app"),
                bundleIdentifier: index < bundleIdentifiers.count ? bundleIdentifiers[index] : nil
            )
        }
        return ApplicationSearchIndex(applications: applications, aliases: aliases)
    }

    func testEmptyAndWhitespaceQueriesReturnNoResults() {
        let index = makeIndex(["Safari"])
        XCTAssertTrue(index.search(query: "").isEmpty)
        XCTAssertTrue(index.search(query: "   ").isEmpty)
    }

    func testOverlongQueryReturnsNoResults() {
        let index = makeIndex([String(repeating: "a", count: 70)])
        XCTAssertFalse(index.search(query: String(repeating: "a", count: 64)).isEmpty)
        XCTAssertTrue(index.search(query: String(repeating: "a", count: 65)).isEmpty)
    }

    func testExactMatchBeatsPrefixMatchWithHeavyUsage() {
        let index = makeIndex(["Safari", "Safarix"])
        var usage: [String: AppUsageRecord] = [
            "/Applications/Safarix.app": AppUsageRecord(launchCount: 100, lastLaunchedAt: Date())
        ]
        let results = index.search(query: "safari", usage: usage)
        XCTAssertEqual(results.map(\.name), ["Safari", "Safarix"])

        usage = [:]
        let withoutUsage = index.search(query: "safarix", usage: usage)
        XCTAssertEqual(withoutUsage.map(\.name), ["Safarix"])
    }

    func testPrefixMatchBeatsSubstringMatch() {
        let index = makeIndex(["Xcode", "MyXcode"])
        XCTAssertEqual(index.search(query: "xcode").map(\.name).first, "Xcode")
        XCTAssertEqual(index.search(query: "xcod").map(\.name).first, "Xcode")
    }

    func testWordPrefixMatchesMiddleWord() {
        let index = makeIndex(["Visual Studio Code"])
        XCTAssertEqual(index.search(query: "code").map(\.name), ["Visual Studio Code"])
        XCTAssertEqual(index.search(query: "studio").map(\.name), ["Visual Studio Code"])
    }

    func testBundleNameAndBundleIdentifierMatch() {
        let index = makeIndex(
            ["Code"],
            bundleIdentifiers: ["com.microsoft.VSCode"]
        )
        let app = AppDescriptor(
            name: "Code",
            url: URL(fileURLWithPath: "/Applications/Visual Studio Code.app"),
            bundleIdentifier: "com.microsoft.VSCode"
        )
        let dedicated = ApplicationSearchIndex(applications: [app])
        XCTAssertEqual(dedicated.search(query: "visual").map(\.name), ["Code"])
        XCTAssertEqual(dedicated.search(query: "commicrosoft").map(\.name), ["Code"])
        XCTAssertEqual(index.search(query: "commicrosoftvscode").map(\.name), ["Code"])
    }

    func testAliasAndInitialsMatch() {
        let app = AppDescriptor(
            name: "Visual Studio Code",
            url: URL(fileURLWithPath: "/Applications/Visual Studio Code.app"),
            bundleIdentifier: "com.example.editor"
        )
        let index = ApplicationSearchIndex(
            applications: [app],
            aliases: ["com.example.editor": ["vscode"]]
        )
        XCTAssertEqual(index.search(query: "vscode").map(\.name), ["Visual Studio Code"])
        XCTAssertEqual(index.search(query: "vsc").map(\.name), ["Visual Studio Code"])
    }

    func testPinyinPrefixMatch() {
        let index = makeIndex(["微信"])
        XCTAssertEqual(index.search(query: "weixin").map(\.name), ["微信"])
        XCTAssertEqual(index.search(query: "wx").map(\.name), ["微信"])
    }

    func testFuzzySubsequenceMatchRanksLast() {
        let index = makeIndex(["Google Chrome", "Google Drive"])
        let results = index.search(query: "gchrme")
        XCTAssertEqual(results.map(\.name), ["Google Chrome"])

        let withBetterMatch = index.search(query: "gch")
        XCTAssertEqual(withBetterMatch.map(\.name), ["Google Chrome"])
    }

    func testAccentAndCaseInsensitiveMatch() {
        let index = makeIndex(["Café Bar"])
        XCTAssertEqual(index.search(query: "cafe bar").map(\.name), ["Café Bar"])
        XCTAssertEqual(index.search(query: "CAFÉ").map(\.name), ["Café Bar"])
    }

    // MARK: 排序与上限

    func testUsageBreaksTiesOnlyWithinSameTier() {
        let index = makeIndex(["Appa", "Appb"])
        var usage: [String: AppUsageRecord] = [
            "/Applications/Appb.app": AppUsageRecord(launchCount: 5, lastLaunchedAt: Date())
        ]
        XCTAssertEqual(index.search(query: "app", usage: usage).map(\.name), ["Appb", "Appa"])

        usage["/Applications/Appb.app"] = AppUsageRecord(launchCount: 5, lastLaunchedAt: nil)
        XCTAssertEqual(index.search(query: "appa", usage: usage).map(\.name), ["Appa"])
    }

    func testRecencyOutranksLaunchCount() {
        let index = makeIndex(["Appa", "Appb"])
        let now = Date()
        let usage: [String: AppUsageRecord] = [
            "/Applications/Appa.app": AppUsageRecord(launchCount: 10, lastLaunchedAt: now.addingTimeInterval(-86_400)),
            "/Applications/Appb.app": AppUsageRecord(launchCount: 2, lastLaunchedAt: now)
        ]
        XCTAssertEqual(index.search(query: "app", usage: usage).map(\.name), ["Appb", "Appa"])
    }

    /// 回归测试：同等级、同位置、同最近启动时间时，启动次数多的排前面。
    func testHigherLaunchCountRanksFirstWithinSameTierAndRecency() {
        let index = makeIndex(["Appa", "Appb"])
        let launchedAt = Date(timeIntervalSinceReferenceDate: 0)
        let usage: [String: AppUsageRecord] = [
            "/Applications/Appa.app": AppUsageRecord(launchCount: 50, lastLaunchedAt: launchedAt),
            "/Applications/Appb.app": AppUsageRecord(launchCount: 2, lastLaunchedAt: launchedAt)
        ]
        XCTAssertEqual(index.search(query: "app", usage: usage).map(\.name), ["Appa", "Appb"])
    }

    func testResultLimitCapsResultsAtFifty() {
        let names = (1...60).map { String(format: "App%02d", $0) }
        let index = makeIndex(names)
        XCTAssertEqual(index.search(query: "app").count, 50)
    }

    func testStableTieBreakFollowsDisplayName() {
        let index = makeIndex(["Beta", "Alpha", "Alpha2"])
        XCTAssertEqual(index.search(query: "alpha").map(\.name), ["Alpha", "Alpha2"])
    }

    // MARK: 使用历史

    func testMemoryUsageStoreRecordsLaunchesAndPrunes() async {
        let store = MemoryAppUsageStore()
        await store.recordLaunch(key: "a")
        await store.recordLaunch(key: "a")

        var records = await store.records()
        XCTAssertEqual(records["a"]?.launchCount, 2)
        XCTAssertNotNil(records["a"]?.lastLaunchedAt)

        await store.prune(keeping: ["b"])
        records = await store.records()
        XCTAssertNil(records["a"])
    }

    func testUserDefaultsUsageStorePersistsAndPrunes() async {
        let suiteName = "OITests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = UserDefaultsAppUsageStore(defaults: defaults)
        await store.recordLaunch(key: "com.example.a")

        let reloaded = UserDefaultsAppUsageStore(defaults: defaults)
        let records = await reloaded.records()
        XCTAssertEqual(records["com.example.a"]?.launchCount, 1)

        await reloaded.prune(keeping: ["com.example.other"])
        let emptied = await reloaded.records()
        XCTAssertTrue(emptied.isEmpty)
    }

    func testChineseAppNameBidirectionalSearch() {
        let app = AppDescriptor(
            name: "微信",
            url: URL(fileURLWithPath: "/Applications/WeChat.app"),
            bundleIdentifier: "com.tencent.xinWeChat"
        )
        let index = ApplicationSearchIndex(applications: [app])
        XCTAssertEqual(index.search(query: "微信").map(\.name), ["微信"])
        XCTAssertEqual(index.search(query: "wx").map(\.name), ["微信"])
        XCTAssertEqual(index.search(query: "weixin").map(\.name), ["微信"])
        XCTAssertEqual(index.search(query: "wechat").map(\.name), ["微信"])
    }

    func testFinderAppNameBidirectionalSearch() {
        let app = AppDescriptor(
            name: "访达",
            url: URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app"),
            bundleIdentifier: "com.apple.finder"
        )
        let index = ApplicationSearchIndex(applications: [app])
        XCTAssertEqual(index.search(query: "访达").map(\.name), ["访达"])
        XCTAssertEqual(index.search(query: "fd").map(\.name), ["访达"])
        XCTAssertEqual(index.search(query: "fangda").map(\.name), ["访达"])
        XCTAssertEqual(index.search(query: "finder").map(\.name), ["访达"])
    }
}
