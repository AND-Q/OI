import Foundation
import XCTest

@testable import OI

@MainActor
final class FileSearchTests: XCTestCase {
    // MARK: - Quick queries

    func testQuickQueryResolverEvaluatesArithmeticAndRejectsInvalidExpressions() {
        let resolver = QuickQueryResolver(ipAddressProvider: MemoryLocalIPAddressProvider())
        XCTAssertEqual(
            resolver.resolve("2 + 3 * (4 - 1)"),
            .calculation(expression: "2 + 3 * (4 - 1)", value: "11")
        )
        XCTAssertEqual(
            resolver.resolve("2^3^2"),
            .calculation(expression: "2^3^2", value: "512")
        )
        XCTAssertEqual(
            resolver.resolve("-2^2"),
            .calculation(expression: "-2^2", value: "-4")
        )
        XCTAssertEqual(
            resolver.resolve("2＋3"),
            .calculation(expression: "2＋3", value: "5")
        )
        XCTAssertEqual(
            resolver.resolve("（2+3）"),
            .calculation(expression: "（2+3）", value: "5")
        )
        XCTAssertNil(resolver.resolve("-1"))
        XCTAssertNil(resolver.resolve("+86"))
        XCTAssertNil(resolver.resolve("2026-09-24"))
        XCTAssertNil(resolver.resolve("2024-05"))
        XCTAssertNil(resolver.resolve("09-24"))
        XCTAssertNil(resolver.resolve("3-1"))
        XCTAssertNil(resolver.resolve("1-2"))
        XCTAssertNil(resolver.resolve("1 / 0"))
        XCTAssertNil(resolver.resolve("notes"))
    }

    /// 回归测试：两段斜杠是除法，不按日期排除；完整的年/月/日仍视为日期。
    func testQuickQueryResolverEvaluatesTwoPartSlashDivision() {
        let resolver = QuickQueryResolver(ipAddressProvider: MemoryLocalIPAddressProvider())
        XCTAssertEqual(
            resolver.resolve("1024/8"),
            .calculation(expression: "1024/8", value: "128")
        )
        XCTAssertEqual(
            resolver.resolve("3600/60"),
            .calculation(expression: "3600/60", value: "60")
        )
        XCTAssertEqual(
            resolver.resolve("10/4"),
            .calculation(expression: "10/4", value: "2.5")
        )
        XCTAssertNil(resolver.resolve("2026/09/24"))
    }

    func testQuickQueryResolverRecognizesLocalIPAliases() {
        let resolver = QuickQueryResolver(ipAddressProvider: MemoryLocalIPAddressProvider(address: "192.168.1.8"))

        XCTAssertEqual(resolver.resolve("本机 IP"), .localIPAddress("192.168.1.8"))
        XCTAssertEqual(resolver.resolve("ip"), .localIPAddress("192.168.1.8"))
        XCTAssertEqual(resolver.resolve("IP 查询"), .localIPAddress("192.168.1.8"))
        XCTAssertEqual(
            QuickQueryResolver(ipAddressProvider: MemoryLocalIPAddressProvider()).resolve("ip"),
            .localIPAddress(nil),
            "取不到地址时仍显示本机 IP 一行"
        )
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
        let included = SpotlightFileSearcher.includedDirectories(homeDirectory: home)
        func isVisible(_ path: String) -> Bool {
            SpotlightFileSearcher.isVisible(path: path, excludedDirectories: excluded, includedDirectories: included)
        }

        XCTAssertTrue(isVisible("/Users/demo/Documents/plan.md"))
        XCTAssertFalse(isVisible("/Users/demo/Library/Caches/x"))
        XCTAssertFalse(isVisible("/Users/demo/.config/plan.md"))
        XCTAssertTrue(isVisible("/Users/demo/LibraryNotes/plan.md"))
    }

    /// iCloud 云盘的本地文件在 `~/Library/Mobile Documents` 下，不随 `~/Library` 一起排除；其中的隐藏路径照常排除。
    func testVisibilityFilterKeepsICloudDriveInsideLibrary() {
        let home = URL(fileURLWithPath: "/Users/demo", isDirectory: true)
        let excluded = SpotlightFileSearcher.excludedDirectories(homeDirectory: home)
        let included = SpotlightFileSearcher.includedDirectories(homeDirectory: home)
        func isVisible(_ path: String) -> Bool {
            SpotlightFileSearcher.isVisible(path: path, excludedDirectories: excluded, includedDirectories: included)
        }

        XCTAssertTrue(isVisible("/Users/demo/Library/Mobile Documents/com~apple~CloudDocs/plan.md"))
        XCTAssertTrue(isVisible("/Users/demo/Library/Mobile Documents/com~apple~Pages/Documents/report.pages"))
        XCTAssertFalse(isVisible("/Users/demo/Library/Mobile Documents/com~apple~CloudDocs/.Trash/old.md"))
        XCTAssertFalse(isVisible("/Users/demo/Library/Mobile DocumentsBackup/plan.md"))
    }

    /// 文件结果的副标题：所在目录以 `~` 缩写；iCloud 云盘的目录按访达的叫法显示，App 文件夹下的 Documents 一层省略，
    /// 取不到 App 文件夹的本地化名称（容器不存在）时显示容器文件夹名。
    func testFileSubtitleShowsICloudDriveLikeFinder() {
        let iCloud = NSHomeDirectory() + "/Library/Mobile Documents"
        func subtitle(_ path: String) -> String? {
            let url = URL(fileURLWithPath: path)
            return LauncherResultsList.Coordinator.subtitle(
                for: .file(FileDescriptor(name: url.lastPathComponent, url: url, isDirectory: false))
            )
        }

        XCTAssertEqual(subtitle(NSHomeDirectory() + "/Documents/plan.md"), "~/Documents")
        XCTAssertEqual(subtitle(NSHomeDirectory() + "/Library/Caches/cache.db"), "~/Library/Caches")
        XCTAssertEqual(subtitle(iCloud + "/com~apple~CloudDocs/plan.md"), "iCloud 云盘")
        XCTAssertEqual(subtitle(iCloud + "/com~apple~CloudDocs/项目/2026/plan.md"), "iCloud 云盘/项目/2026")
        XCTAssertEqual(
            subtitle(iCloud + "/iCloud~com~example~Missing/Documents/Notes/plan.md"),
            "iCloud 云盘/iCloud~com~example~Missing/Notes"
        )
        XCTAssertNil(subtitle("/"))
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

    // MARK: - Path

    /// 输入存在的路径时置顶显示该条目，不做文件搜索；首尾空白去掉后连同 `~` 原样按路径查找。
    func testViewModelPinsExistingPathAndSkipsFileSearch() async {
        let folder = FileDescriptor(
            name: "Caches",
            url: URL(fileURLWithPath: "/Users/demo/Library/Caches"),
            isDirectory: true
        )
        let opener = StubFileOpener()
        opener.items = ["~/Library/Caches": folder]
        let searcher = StubFileSearcher(results: [file("Caches.txt")])
        let viewModel = makeViewModel(apps: [], searcher: searcher, opener: opener)
        await viewModel.loadApps()?.value

        viewModel.query = " ~/Library/Caches "
        await viewModel.waitForFileSearch()
        await waitUntil { viewModel.pathResult != nil }

        XCTAssertEqual(opener.lookedUpPaths.last, "~/Library/Caches")
        XCTAssertEqual(viewModel.results, [.file(folder)])
        XCTAssertEqual(viewModel.rows, [.result(.file(folder))])
        XCTAssertEqual(viewModel.selectedResult, .file(folder))
        XCTAssertTrue(searcher.queries.isEmpty, "输入路径时不做文件搜索")
    }

    /// 路径不存在时不显示路径行，也不列出名称无关的文件；不是路径的输入不按路径查找，照常搜索文件。
    func testViewModelHidesMissingPathAndSearchesFilesForOtherQueries() async {
        let opener = StubFileOpener()
        let searcher = StubFileSearcher(results: [file("notes.txt")])
        let viewModel = makeViewModel(apps: [], searcher: searcher, opener: opener)
        await viewModel.loadApps()?.value

        viewModel.query = "/Users/demo/missing"
        await viewModel.waitForFileSearch()
        await waitUntil { opener.lookedUpPaths.count == 1 }

        XCTAssertNil(viewModel.pathResult)
        XCTAssertTrue(viewModel.results.isEmpty)
        XCTAssertTrue(searcher.queries.isEmpty)

        viewModel.query = "notes"
        await viewModel.waitForFileSearch()

        XCTAssertNil(viewModel.pathResult)
        XCTAssertEqual(opener.lookedUpPaths, ["/Users/demo/missing"])
        XCTAssertEqual(searcher.queries, ["notes"])
        XCTAssertEqual(viewModel.results, [.file(file("notes.txt"))])
    }

    /// 后台查看比新的输入晚到时丢弃：先输入的慢路径结果到达后，直达行仍是最新输入的路径。
    func testViewModelDropsSupersededPathLookup() async {
        let slow = FileDescriptor(name: "NAS", url: URL(fileURLWithPath: "/Volumes/NAS"), isDirectory: true)
        let fast = FileDescriptor(name: "tmp", url: URL(fileURLWithPath: "/tmp"), isDirectory: true)
        let opener = StubFileOpener()
        opener.items = ["/Volumes/NAS": slow, "/tmp": fast]
        opener.delays = ["/Volumes/NAS": .milliseconds(100)]
        let viewModel = makeViewModel(apps: [], searcher: StubFileSearcher(results: []), opener: opener)
        await viewModel.loadApps()?.value

        viewModel.query = "/Volumes/NAS"
        viewModel.query = "/tmp"
        await waitUntil { viewModel.pathResult == fast }
        try? await Task.sleep(for: .milliseconds(200))

        XCTAssertEqual(Set(opener.lookedUpPaths), ["/Volumes/NAS", "/tmp"])
        XCTAssertEqual(viewModel.pathResult, fast)
        XCTAssertEqual(viewModel.selectedResult, .file(fast))
    }

    /// 按路径直接查看文件系统：隐藏文件、带结尾斜杠的文件夹、`.app` 文件包与 `~` 都能取到，不存在的路径为 nil。
    func testWorkspaceOpenerFindsItemsByPath() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let hidden = root.appendingPathComponent(".env")
        try Data().write(to: hidden)
        let package = root.appendingPathComponent("Demo.app", isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        let opener = WorkspaceFileOpener()

        let foundHidden = await opener.item(atPath: hidden.path)
        let hiddenItem = try XCTUnwrap(foundHidden)
        XCTAssertEqual(hiddenItem.name, ".env")
        XCTAssertEqual(hiddenItem.url, hidden.standardizedFileURL)
        XCTAssertFalse(hiddenItem.isDirectory)

        let foundFolder = await opener.item(atPath: root.path + "/")
        let folder = try XCTUnwrap(foundFolder)
        XCTAssertEqual(folder.url.path, root.standardizedFileURL.path)
        XCTAssertTrue(folder.isDirectory)

        let foundPackage = await opener.item(atPath: package.path)
        let packageItem = try XCTUnwrap(foundPackage)
        XCTAssertFalse(packageItem.isDirectory, "文件包按文件处理")

        let foundHome = await opener.item(atPath: "~")
        let home = try XCTUnwrap(foundHome)
        XCTAssertEqual(home.url.path, FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path)
        XCTAssertTrue(home.isDirectory)

        let missing = await opener.item(atPath: root.appendingPathComponent("missing").path)
        XCTAssertNil(missing)
        let unknownUser = await opener.item(atPath: "~no-such-user-\(UUID().uuidString)")
        XCTAssertNil(unknownUser, "展开后不是绝对路径")
    }

    private func makeViewModel(
        apps: [AppDescriptor],
        searcher: StubFileSearcher,
        opener: StubFileOpener = StubFileOpener(),
        settingsStore: any AppSettingsStoring = MemoryAppSettingsStore()
    ) -> LauncherViewModel {
        LauncherViewModel(
            discoverApplications: DiscoverApplications(catalog: StubAppCatalog(descriptors: apps)),
            launchApplication: LaunchApplication(launcher: StubApplicationLauncher()),
            searchFiles: SearchFiles(searcher: searcher, limit: 10),
            openFile: OpenFile(opener: opener),
            settingsStore: settingsStore,
            fileSearchDebounce: .zero
        )
    }

    private func waitUntil(timeout: Duration = .seconds(2), _ condition: () -> Bool) async {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while !condition(), clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
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
    /// Items found by `item(atPath:)`, keyed by the path as typed.
    var items: [String: FileDescriptor] = [:]
    /// 查看这些路径时先等待，且不响应取消，模拟卡住的网络卷。
    var delays: [String: Duration] = [:]
    private(set) var lookedUpPaths: [String] = []

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

    func item(atPath path: String) async -> FileDescriptor? {
        lookedUpPaths.append(path)
        if let delay = delays[path] {
            _ = await Task.detached { try? await Task.sleep(for: delay) }.value
        }
        return items[path]
    }
}

private struct StubFileSearchError: LocalizedError {
    var errorDescription: String? { "文件搜索失败" }
}
