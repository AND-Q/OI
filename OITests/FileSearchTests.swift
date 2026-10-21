import Foundation
import XCTest

@testable import OI

@MainActor
final class FileSearchTests: XCTestCase {
    // MARK: - Quick queries

    func testQuickQueryResolverEvaluatesArithmeticAndRejectsInvalidExpressions() {
        XCTAssertEqual(
            QuickQueryResolver.resolve("2 + 3 * (4 - 1)"),
            .calculation(expression: "2 + 3 * (4 - 1)", value: "11")
        )
        XCTAssertEqual(
            QuickQueryResolver.resolve("2^3^2"),
            .calculation(expression: "2^3^2", value: "512")
        )
        XCTAssertEqual(
            QuickQueryResolver.resolve("-2^2"),
            .calculation(expression: "-2^2", value: "-4")
        )
        XCTAssertEqual(
            QuickQueryResolver.resolve("2＋3"),
            .calculation(expression: "2＋3", value: "5")
        )
        XCTAssertEqual(
            QuickQueryResolver.resolve("（2+3）"),
            .calculation(expression: "（2+3）", value: "5")
        )
        XCTAssertNil(QuickQueryResolver.resolve("-1"))
        XCTAssertNil(QuickQueryResolver.resolve("+86"))
        XCTAssertNil(QuickQueryResolver.resolve("2026-09-24"))
        XCTAssertNil(QuickQueryResolver.resolve("2024-05"))
        XCTAssertNil(QuickQueryResolver.resolve("09-24"))
        XCTAssertNil(QuickQueryResolver.resolve("3-1"))
        XCTAssertNil(QuickQueryResolver.resolve("1-2"))
        XCTAssertNil(QuickQueryResolver.resolve("1 / 0"))
        XCTAssertNil(QuickQueryResolver.resolve("notes"))
    }

    /// 回归测试：两段斜杠是除法，不按日期排除；完整的年/月/日仍视为日期。
    func testQuickQueryResolverEvaluatesTwoPartSlashDivision() {
        XCTAssertEqual(
            QuickQueryResolver.resolve("1024/8"),
            .calculation(expression: "1024/8", value: "128")
        )
        XCTAssertEqual(
            QuickQueryResolver.resolve("3600/60"),
            .calculation(expression: "3600/60", value: "60")
        )
        XCTAssertEqual(
            QuickQueryResolver.resolve("10/4"),
            .calculation(expression: "10/4", value: "2.5")
        )
        XCTAssertNil(QuickQueryResolver.resolve("2026/09/24"))
    }

    func testQuickQueryResolverRecognizesLocalIPAliases() {
        guard case .localIPAddress = QuickQueryResolver.resolve("本机 IP") else {
            return XCTFail("Expected the local IP quick query")
        }
        guard case .localIPAddress = QuickQueryResolver.resolve("ip") else {
            return XCTFail("Expected the short IP alias")
        }
        guard case .localIPAddress = QuickQueryResolver.resolve("IP 查询") else {
            return XCTFail("Expected the IP query alias")
        }
    }

    func testViewModelKeepsApplicationAndFileResultsBelowQuickQuery() async {
        let app = AppDescriptor(name: "2+2", url: URL(fileURLWithPath: "/Applications/2+2.app"))
        let searcher = StubFileSearcher(results: [file("2+2.txt")])
        let viewModel = makeViewModel(apps: [app], searcher: searcher)
        await viewModel.loadApps()?.value

        viewModel.query = "2+2"
        await viewModel.waitForFileSearch()

        XCTAssertEqual(viewModel.results, [
            .quickQuery(.calculation(expression: "2+2", value: "4")),
            .application(app),
            .file(file("2+2.txt"))
        ])
        XCTAssertEqual(viewModel.rows, [
            .result(.quickQuery(.calculation(expression: "2+2", value: "4"))),
            .result(.application(app)),
            .sectionHeader(LauncherViewModel.fileSectionTitle),
            .result(.file(file("2+2.txt")))
        ])
        XCTAssertEqual(viewModel.selectedResult, .quickQuery(.calculation(expression: "2+2", value: "4")))
        XCTAssertEqual(viewModel.expandedContent, .results(rowCount: 3, sectionHeaderCount: 1))
        XCTAssertEqual(searcher.queries, ["2+2"])

        viewModel.moveSelection(by: 1)
        XCTAssertEqual(viewModel.selectedResult, .application(app))
        XCTAssertEqual(viewModel.selectedRowIndex, 1)
        viewModel.moveSelection(by: 1)
        XCTAssertEqual(viewModel.selectedResult, .file(file("2+2.txt")))
        XCTAssertEqual(viewModel.selectedRowIndex, 3)
    }

    // MARK: - FileResultRanker

    func testRankerPutsExactNameFirstThenPrefixThenOthers() {
        let files = [
            file("notes-readme.md"),
            file("Readme Draft.txt"),
            file("readme"),
            file("another readme.md")
        ]

        let ranked = FileResultRanker.rank(files, query: "readme")

        XCTAssertEqual(ranked.map(\.name), [
            "readme",
            "Readme Draft.txt",
            "notes-readme.md",
            "another readme.md"
        ])
    }

    func testRankerKeepsInputOrderWithinTier() {
        let files = [file("b.txt"), file("a.txt"), file("c.txt")]

        let ranked = FileResultRanker.rank(files, query: "zzz")

        XCTAssertEqual(ranked, files)
    }

    /// 去掉扩展名后完全一致的文件视为完全匹配，排在同为前缀匹配的长名字之前。
    func testRankerTreatsStemMatchAsExactMatch() {
        let files = [
            file("readme-notes-2026.txt"),
            file("README.md"),
            file("readme.txt")
        ]

        let ranked = FileResultRanker.rank(files, query: "readme")

        XCTAssertEqual(ranked.map(\.name), ["README.md", "readme.txt", "readme-notes-2026.txt"])
    }

    // MARK: - SearchFiles

    /// 同级内按活跃时间降序：刚下载（从未打开、仅有加入时间）的文件要排在几周前打开过的文件之前。
    func testRankerOrdersSameTierByActivityDateThenInputOrder() {
        let now = Date()
        let openedWeeksAgo = file("report-final.pdf", activityDate: now.addingTimeInterval(-21 * 86_400))
        let justDownloaded = file("report-v2.pdf", activityDate: now)
        let sameTimeA = file("report-a.pdf", activityDate: now.addingTimeInterval(-3600))
        let sameTimeB = file("report-b.pdf", activityDate: now.addingTimeInterval(-3600))
        let exactButOld = file("report.pdf", activityDate: now.addingTimeInterval(-90 * 86_400))

        let ranked = FileResultRanker.rank(
            [openedWeeksAgo, sameTimeA, justDownloaded, sameTimeB, exactButOld],
            query: "report"
        )

        XCTAssertEqual(ranked.map(\.name), [
            "report.pdf",
            "report-v2.pdf",
            "report-a.pdf",
            "report-b.pdf",
            "report-final.pdf"
        ])
    }

    /// 回归测试：候选池必须先排序再截断，完全匹配的文件不能因为不在最近使用的前几条而被丢掉。
    func testSearchFilesRanksBeforeTruncatingToDisplayLimit() async throws {
        var candidates = (1...14).map { file("readme-log-\($0).txt") }
        candidates.insert(file("readme.md"), at: 11)
        let searcher = StubFileSearcher(results: candidates)
        let searchFiles = SearchFiles(searcher: searcher, limit: 10)

        let results = try await searchFiles.execute(query: "readme")

        XCTAssertEqual(searcher.requestedLimits, [SearchFiles.candidateLimit])
        XCTAssertEqual(results.count, 10)
        XCTAssertEqual(results.first?.name, "readme.md")
        XCTAssertEqual(results[1].name, "readme-log-1.txt")
    }

    // MARK: - SpotlightFileSearcher helpers

    func testQueryStringEscapesMetadataSpecialCharacters() {
        XCTAssertEqual(SpotlightFileSearcher.escape(#"a"b\c*d?"#), #"a\"b\\c\*d\?"#)
        XCTAssertEqual(
            SpotlightFileSearcher.queryString(for: "plan"),
            "kMDItemDisplayName == \"plan*\"cdw && kMDItemContentTypeTree != \"com.apple.application-bundle\""
        )
    }

    func testVisibilityFilterExcludesLibraryAndHiddenPaths() {
        let home = URL(fileURLWithPath: "/Users/demo", isDirectory: true)
        let excluded = SpotlightFileSearcher.excludedDirectories(homeDirectory: home)

        XCTAssertTrue(SpotlightFileSearcher.isVisible(path: "/Users/demo/Documents/plan.md", excludedDirectories: excluded))
        XCTAssertFalse(SpotlightFileSearcher.isVisible(path: "/Users/demo/Library/Caches/x", excludedDirectories: excluded))
        XCTAssertFalse(SpotlightFileSearcher.isVisible(path: "/Users/demo/.config/plan.md", excludedDirectories: excluded))
        XCTAssertTrue(SpotlightFileSearcher.isVisible(path: "/Users/demo/LibraryNotes/plan.md", excludedDirectories: excluded))
    }

    // MARK: - ViewModel integration

    func testViewModelAppendsFileResultsAfterApplicationsWithSectionHeader() async {
        let xcode = AppDescriptor(name: "Xcode", url: URL(fileURLWithPath: "/Applications/Xcode.app"))
        let searcher = StubFileSearcher(results: [file("xcode-notes.md"), file("xcconfig")])
        let viewModel = makeViewModel(apps: [xcode], searcher: searcher)
        await viewModel.loadApps()?.value

        viewModel.query = "xc"
        XCTAssertEqual(viewModel.fileSearchState, .searching)
        await viewModel.waitForFileSearch()

        XCTAssertEqual(viewModel.fileSearchState, .loaded)
        XCTAssertEqual(viewModel.results.map(\.name), ["Xcode", "xcode-notes.md", "xcconfig"])
        XCTAssertEqual(viewModel.rows, [
            .result(.application(xcode)),
            .sectionHeader(LauncherViewModel.fileSectionTitle),
            .result(.file(file("xcode-notes.md"))),
            .result(.file(file("xcconfig")))
        ])
        XCTAssertEqual(viewModel.selectedIndex, 0)
        XCTAssertEqual(viewModel.selectedRowIndex, 0)
        XCTAssertEqual(
            viewModel.panelHeight,
            LauncherLayout.totalHeight(isExpanded: true, content: .results(rowCount: 3, sectionHeaderCount: 1))
        )
    }

    func testViewModelSkipsHeaderWhenMappingSelectionToRows() async {
        let xcode = AppDescriptor(name: "Xcode", url: URL(fileURLWithPath: "/Applications/Xcode.app"))
        let searcher = StubFileSearcher(results: [file("xc1"), file("xc2")])
        let viewModel = makeViewModel(apps: [xcode], searcher: searcher)
        await viewModel.loadApps()?.value

        viewModel.query = "xc"
        await viewModel.waitForFileSearch()

        viewModel.moveSelection(by: 1)
        XCTAssertEqual(viewModel.selectedResult?.name, "xc1")
        XCTAssertEqual(viewModel.selectedRowIndex, 2)

        viewModel.moveSelection(by: 5)
        XCTAssertEqual(viewModel.selectedResult?.name, "xc2")
        XCTAssertEqual(viewModel.selectedIndex, 2)
        XCTAssertEqual(viewModel.selectedRowIndex, 3)
    }

    func testViewModelDoesNotSearchFilesBelowMinimumLengthAndClearsOnEmptyQuery() async {
        let searcher = StubFileSearcher(results: [file("anything")])
        let viewModel = makeViewModel(apps: [], searcher: searcher)
        await viewModel.loadApps()?.value

        viewModel.query = "a"
        XCTAssertEqual(viewModel.fileSearchState, .idle)
        await Task.yield()
        XCTAssertEqual(searcher.queries, [])

        viewModel.query = "an"
        await viewModel.waitForFileSearch()
        XCTAssertEqual(searcher.queries, ["an"])
        XCTAssertEqual(viewModel.fileResults.map(\.name), ["anything"])

        viewModel.query = ""
        XCTAssertTrue(viewModel.fileResults.isEmpty)
        XCTAssertEqual(viewModel.fileSearchState, .idle)
        XCTAssertFalse(viewModel.isExpanded)
    }

    func testViewModelKeepsOnlyLatestQueryResults() async {
        let searcher = StubFileSearcher(results: [file("stale")])
        searcher.delay = .milliseconds(50)
        let viewModel = makeViewModel(apps: [], searcher: searcher)
        await viewModel.loadApps()?.value

        viewModel.query = "st"
        searcher.results = [file("fresh")]
        viewModel.query = "fr"
        await viewModel.waitForFileSearch()

        XCTAssertEqual(viewModel.fileResults.map(\.name), ["fresh"])
        XCTAssertEqual(searcher.queries.last, "fr")
    }

    func testViewModelShowsApplicationsWhenFileSearchFails() async {
        let xcode = AppDescriptor(name: "Xcode", url: URL(fileURLWithPath: "/Applications/Xcode.app"))
        let searcher = StubFileSearcher(results: [])
        searcher.error = StubFileSearchError()
        let viewModel = makeViewModel(apps: [xcode], searcher: searcher)
        await viewModel.loadApps()?.value

        viewModel.query = "xc"
        await viewModel.waitForFileSearch()

        XCTAssertEqual(viewModel.fileSearchState, .loaded)
        XCTAssertTrue(viewModel.fileResults.isEmpty)
        XCTAssertEqual(viewModel.expandedContent, .results(rowCount: 1))
        XCTAssertNil(viewModel.errorMessage)
    }

    /// 回归测试：连续输入时保留上一批文件结果，面板不得在状态页与列表之间来回跳动。
    func testViewModelKeepsPreviousFileResultsWhileNextSearchIsInFlight() async {
        let searcher = StubFileSearcher(results: [file("bicycle.svg")])
        let viewModel = makeViewModel(apps: [], searcher: searcher)
        await viewModel.loadApps()?.value

        viewModel.query = "bi"
        await viewModel.waitForFileSearch()
        let listHeight = viewModel.panelHeight
        XCTAssertEqual(viewModel.expandedContent, .results(rowCount: 1, sectionHeaderCount: 1))

        searcher.delay = .milliseconds(50)
        searcher.results = [file("bicycle.svg"), file("bike.txt")]
        viewModel.query = "bic"

        XCTAssertEqual(viewModel.fileSearchState, .searching)
        XCTAssertEqual(viewModel.fileResults.map(\.name), ["bicycle.svg"])
        XCTAssertEqual(viewModel.panelHeight, listHeight)
        XCTAssertNotEqual(viewModel.expandedContent, .status)

        await viewModel.waitForFileSearch()
        XCTAssertEqual(viewModel.fileResults.map(\.name), ["bicycle.svg", "bike.txt"])

        // 失败时才清空，避免旧结果与新查询长期不符。
        searcher.error = StubFileSearchError()
        viewModel.query = "bicy"
        await viewModel.waitForFileSearch()
        XCTAssertTrue(viewModel.fileResults.isEmpty)
        XCTAssertEqual(viewModel.expandedContent, .status)
    }

    /// 回归测试：检索在途期间只保留名称仍包含新查询的旧结果，回车不能打开与当前输入不符的旧文件。
    func testViewModelDropsPreviousFileResultsThatNoLongerMatchQuery() async {
        let searcher = StubFileSearcher(results: [file("repo-notes.txt"), file("Report.pdf")])
        let viewModel = makeViewModel(apps: [], searcher: searcher)
        await viewModel.loadApps()?.value

        viewModel.query = "repo"
        await viewModel.waitForFileSearch()
        XCTAssertEqual(viewModel.selectedResult?.name, "repo-notes.txt")

        searcher.delay = .milliseconds(50)
        searcher.results = [file("Report.pdf")]
        viewModel.query = "report"

        XCTAssertEqual(viewModel.fileSearchState, .searching)
        XCTAssertEqual(viewModel.fileResults.map(\.name), ["Report.pdf"])
        XCTAssertEqual(viewModel.selectedResult?.name, "Report.pdf")
    }

    /// 回归测试：新结果在途期间用方向键下移后，结果变短时光标贴到最后一条、变空归零、变长不动。
    func testViewModelClampsSelectionWhenAsyncFileResultsShrink() async {
        let searcher = StubFileSearcher(results: [file("r1"), file("r1b"), file("r1c")])
        let viewModel = makeViewModel(apps: [], searcher: searcher)
        await viewModel.loadApps()?.value

        viewModel.query = "r1"
        await viewModel.waitForFileSearch()

        // 变短且越界：贴到最后一条，仍可回车。
        searcher.delay = .milliseconds(50)
        searcher.results = [file("r1")]
        viewModel.query = "r1 "
        viewModel.moveSelection(by: 2)
        XCTAssertEqual(viewModel.selectedIndex, 2)
        await viewModel.waitForFileSearch()
        XCTAssertEqual(viewModel.selectedIndex, 0)
        XCTAssertEqual(viewModel.selectedResult?.name, "r1")

        // 变空：归零。
        searcher.results = []
        viewModel.query = "r1"
        await viewModel.waitForFileSearch()
        XCTAssertEqual(viewModel.selectedIndex, 0)
        XCTAssertNil(viewModel.selectedResult)

        // 变长：光标不动。
        searcher.results = [file("r1"), file("r1b")]
        viewModel.query = "r1 "
        await viewModel.waitForFileSearch()
        searcher.results = [file("r1"), file("r1b"), file("r1c"), file("r1d")]
        viewModel.query = "r1"
        viewModel.moveSelection(by: 1)
        await viewModel.waitForFileSearch()
        XCTAssertEqual(viewModel.selectedIndex, 1)
        XCTAssertEqual(viewModel.selectedResult?.name, "r1b")
    }

    func testViewModelStaysIdleAfterCancellingInFlightFileSearch() async {
        let searcher = StubFileSearcher(results: [file("late")])
        searcher.delay = .milliseconds(50)
        let viewModel = makeViewModel(apps: [], searcher: searcher)
        await viewModel.loadApps()?.value

        viewModel.query = "la"
        XCTAssertEqual(viewModel.fileSearchState, .searching)
        viewModel.cancelOperations()
        // 给被取消的任务留出回到主线程执行 catch 分支的时间。
        try? await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(viewModel.fileSearchState, .idle)
        XCTAssertTrue(viewModel.fileResults.isEmpty)
    }

    func testViewModelOpensFileWithoutRecordingUsageAndRevealsInFinder() async {
        let opener = StubFileOpener()
        let store = MemoryAppUsageStore()
        let viewModel = LauncherViewModel(
            discoverApplications: DiscoverApplications(catalog: StubAppCatalog(descriptors: [])),
            launchApplication: LaunchApplication(launcher: StubApplicationLauncher()),
            openFile: OpenFile(opener: opener),
            usageStore: store
        )
        let plan = file("plan.md")

        await viewModel.open(.file(plan))?.value
        XCTAssertEqual(opener.openedFiles, [plan])
        let records = await store.records()
        XCTAssertTrue(records.isEmpty)

        viewModel.reveal(.file(plan))
        XCTAssertEqual(opener.revealedURLs, [plan.url])
    }

    func testViewModelOpenInTerminalForwardsDirectoryToOpener() async {
        let opener = StubFileOpener()
        let viewModel = LauncherViewModel(
            discoverApplications: DiscoverApplications(catalog: StubAppCatalog(descriptors: [])),
            launchApplication: LaunchApplication(launcher: StubApplicationLauncher()),
            openFile: OpenFile(opener: opener),
            usageStore: MemoryAppUsageStore()
        )
        let plan = file("plan.md")

        viewModel.openInTerminal(url: plan.url.deletingLastPathComponent())

        XCTAssertEqual(opener.terminalURLs, [plan.url.deletingLastPathComponent()])
    }

    func testViewModelOpensFileWithChosenApplication() async {
        let opener = StubFileOpener()
        let editor = OpenWithApplication(
            url: URL(fileURLWithPath: "/Applications/Visual Studio Code.app"),
            name: "Visual Studio Code",
            isDefault: false
        )
        opener.applications = [editor]
        let notifier = MemoryUserNotifier()
        let viewModel = LauncherViewModel(
            discoverApplications: DiscoverApplications(catalog: StubAppCatalog(descriptors: [])),
            launchApplication: LaunchApplication(launcher: StubApplicationLauncher()),
            openFile: OpenFile(opener: opener),
            notifier: notifier
        )
        let plan = file("plan.md")

        XCTAssertEqual(viewModel.applications(toOpen: plan), [editor])
        await viewModel.open(plan, withApplicationAt: editor.url)?.value
        XCTAssertEqual(opener.openedWithApplications.map(\.file), [plan])
        XCTAssertEqual(opener.openedWithApplications.map(\.applicationURL), [editor.url])

        opener.error = StubFileSearchError()
        await viewModel.open(plan, withApplicationAt: editor.url)?.value
        XCTAssertEqual(notifier.records, [MemoryUserNotifier.Record(title: "无法打开 plan.md", body: "文件搜索失败")])
    }

    func testViewModelNotifiesFileOpenFailure() async {
        let opener = StubFileOpener()
        opener.error = StubFileSearchError()
        let notifier = MemoryUserNotifier()
        let viewModel = LauncherViewModel(
            discoverApplications: DiscoverApplications(catalog: StubAppCatalog(descriptors: [])),
            launchApplication: LaunchApplication(launcher: StubApplicationLauncher()),
            openFile: OpenFile(opener: opener),
            notifier: notifier
        )

        await viewModel.open(.file(file("plan.md")))?.value

        XCTAssertEqual(notifier.records, [MemoryUserNotifier.Record(title: "无法打开 plan.md", body: "文件搜索失败")])
        XCTAssertNil(viewModel.launchErrorMessage)
    }

    // MARK: - Helpers

    private func file(_ name: String, activityDate: Date = .distantPast) -> FileDescriptor {
        FileDescriptor(
            name: name,
            url: URL(fileURLWithPath: "/Users/demo/Documents/\(name)"),
            isDirectory: false,
            activityDate: activityDate
        )
    }

    func testViewModelSkipsFileSearchWhenDisabledInSettings() async {
        let searcher = StubFileSearcher(results: [file("anything.txt")])
        let settingsStore = MemoryAppSettingsStore(initial: AppSettings(isFileSearchEnabled: false))
        let viewModel = makeViewModel(apps: [], searcher: searcher, settingsStore: settingsStore)
        await viewModel.loadApps()?.value

        viewModel.query = "anything"
        await viewModel.waitForFileSearch()

        XCTAssertTrue(searcher.queries.isEmpty)
        XCTAssertEqual(viewModel.fileResults, [])

        // 重新开启后恢复文件搜索。
        settingsStore.save(AppSettings())
        viewModel.query = "anythin"
        await viewModel.waitForFileSearch()

        XCTAssertEqual(searcher.queries, ["anythin"])
        XCTAssertEqual(viewModel.fileResults.map(\.name), ["anything.txt"])
    }

    private func makeViewModel(
        apps: [AppDescriptor],
        searcher: StubFileSearcher,
        settingsStore: any AppSettingsStoring = MemoryAppSettingsStore()
    ) -> LauncherViewModel {
        LauncherViewModel(
            discoverApplications: DiscoverApplications(catalog: StubAppCatalog(descriptors: apps)),
            launchApplication: LaunchApplication(launcher: StubApplicationLauncher()),
            searchFiles: SearchFiles(searcher: searcher, limit: 10),
            openFile: OpenFile(opener: StubFileOpener()),
            settingsStore: settingsStore,
            fileSearchDebounce: .zero
        )
    }
}

private extension LauncherViewModel {
    func waitForFileSearch(timeout: Duration = .seconds(2)) async {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while fileSearchState == .searching, clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }
}

@MainActor
private final class StubFileSearcher: FileSearching {
    var results: [FileDescriptor]
    var delay: Duration = .zero
    var error: Error?
    private(set) var queries: [String] = []
    private(set) var requestedLimits: [Int] = []

    init(results: [FileDescriptor]) {
        self.results = results
    }

    func search(query: String, limit: Int) async throws -> [FileDescriptor] {
        queries.append(query)
        requestedLimits.append(limit)
        if delay != .zero {
            try await Task.sleep(for: delay)
        }
        if let error { throw error }
        return Array(results.prefix(limit))
    }
}

@MainActor
private final class StubFileOpener: FileOpening {
    var error: Error?
    private(set) var openedFiles: [FileDescriptor] = []
    private(set) var revealedURLs: [URL] = []
    private(set) var terminalURLs: [URL] = []
    private(set) var openedWithApplications: [(file: FileDescriptor, applicationURL: URL)] = []
    var applications: [OpenWithApplication] = []

    func open(_ file: FileDescriptor) async throws {
        if let error { throw error }
        openedFiles.append(file)
    }

    func applications(toOpen file: FileDescriptor) -> [OpenWithApplication] {
        applications
    }

    func open(_ file: FileDescriptor, withApplicationAt applicationURL: URL) async throws {
        if let error { throw error }
        openedWithApplications.append((file: file, applicationURL: applicationURL))
    }

    func revealInFinder(url: URL) {
        revealedURLs.append(url)
    }

    func openInTerminal(url: URL) {
        terminalURLs.append(url)
    }
}

private struct StubFileSearchError: LocalizedError {
    var errorDescription: String? { "文件搜索失败" }
}
