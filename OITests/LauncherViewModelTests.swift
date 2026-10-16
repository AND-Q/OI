import Combine
import Foundation
import XCTest

@testable import OI

@MainActor
final class LauncherViewModelTests: XCTestCase {
    // MARK: - 加载与过滤

    func testViewModelLoadsAndFiltersApplications() async {
        let apps = [
            AppDescriptor(name: "Safari", url: URL(fileURLWithPath: "/Applications/Safari.app")),
            AppDescriptor(name: "Notes", url: URL(fileURLWithPath: "/Applications/Notes.app")),
            AppDescriptor(name: "Xcode", url: URL(fileURLWithPath: "/Applications/Xcode.app"))
        ]
        let viewModel = makeViewModel(with: apps)

        await viewModel.loadApps()?.value

        XCTAssertEqual(viewModel.apps, apps)
        XCTAssertEqual(viewModel.filteredApps, apps)

        viewModel.query = "code"
        XCTAssertEqual(viewModel.filteredApps.map(\.name), ["Xcode"])
        XCTAssertEqual(viewModel.selectedApp?.name, "Xcode")
    }

    func testViewModelDoesNotExposeSelectionForEmptyQuery() async {
        let app = AppDescriptor(
            name: "Alpha",
            url: URL(fileURLWithPath: "/Applications/Alpha.app")
        )
        let viewModel = makeViewModel(with: [app])

        await viewModel.loadApps()?.value

        XCTAssertNil(viewModel.selectedApp)

        viewModel.query = "Alpha"
        XCTAssertEqual(viewModel.selectedApp, app)
    }

    /// 回归测试：纯空白输入按空查询处理（文档 §8.3）——面板保持折叠、不暴露可启动选中项。
    func testViewModelTreatsWhitespaceOnlyQueryAsEmpty() async {
        let app = AppDescriptor(
            name: "Alpha",
            url: URL(fileURLWithPath: "/Applications/Alpha.app")
        )
        let viewModel = makeViewModel(with: [app])

        await viewModel.loadApps()?.value

        viewModel.query = "   "

        XCTAssertFalse(viewModel.isExpanded)
        XCTAssertNil(viewModel.selectedApp)
        XCTAssertEqual(viewModel.panelHeight, LauncherLayout.searchHeight)
    }

    func testViewModelResetsSelectionAndScrollWhenFilteringResults() async {
        let apps = [
            AppDescriptor(name: "Alpha", url: URL(fileURLWithPath: "/Applications/Alpha.app")),
            AppDescriptor(name: "Almanac", url: URL(fileURLWithPath: "/Applications/Almanac.app")),
            AppDescriptor(name: "Arc", url: URL(fileURLWithPath: "/Applications/Arc.app"))
        ]
        let viewModel = makeViewModel(with: apps)

        await viewModel.loadApps()?.value
        viewModel.moveSelection(by: 2)
        let previousResetRequest = viewModel.listResetRequest
        viewModel.query = "a"

        XCTAssertEqual(viewModel.selectedIndex, 0)
        // 同等级、同分数的结果按名称稳定排序：Almanac < Alpha < Arc。
        XCTAssertEqual(viewModel.selectedApp?.name, "Almanac")
        XCTAssertGreaterThan(viewModel.listResetRequest, previousResetRequest)
    }

    func testViewModelResetsSelectionAndScrollWhenPresentedAgain() async {
        let apps = [
            AppDescriptor(name: "Alpha", url: URL(fileURLWithPath: "/Applications/Alpha.app")),
            AppDescriptor(name: "Beta", url: URL(fileURLWithPath: "/Applications/Beta.app")),
            AppDescriptor(name: "Gamma", url: URL(fileURLWithPath: "/Applications/Gamma.app"))
        ]
        let viewModel = makeViewModel(with: apps)

        await viewModel.loadApps()?.value
        viewModel.moveSelection(by: 2)
        let previousResetRequest = viewModel.listResetRequest

        viewModel.prepareForPresentation()

        XCTAssertEqual(viewModel.filteredApps, apps)
        XCTAssertEqual(viewModel.selectedIndex, 0)
        XCTAssertGreaterThan(viewModel.listResetRequest, previousResetRequest)
    }

    func testViewModelPublishesFinalPanelHeightAfterFiltering() async {
        let apps = [
            AppDescriptor(name: "Alpha", url: URL(fileURLWithPath: "/Applications/Alpha.app")),
            AppDescriptor(name: "Beta", url: URL(fileURLWithPath: "/Applications/Beta.app")),
            AppDescriptor(name: "Gamma", url: URL(fileURLWithPath: "/Applications/Gamma.app"))
        ]
        let viewModel = makeViewModel(with: apps)
        await viewModel.loadApps()?.value

        var publishedHeights: [CGFloat] = []
        let cancellable = viewModel.$panelHeight
            .dropFirst()
            .sink { publishedHeights.append($0) }

        viewModel.query = "Alpha"
        viewModel.query = "Missing"
        viewModel.query = ""

        XCTAssertEqual(publishedHeights, [
            LauncherLayout.totalHeight(isExpanded: true, content: .results(rowCount: 1)),
            LauncherLayout.totalHeight(isExpanded: true, content: .status),
            LauncherLayout.searchHeight
        ])
        withExtendedLifetime(cancellable) {}
    }

    // MARK: - 启动与错误发布

    func testViewModelLaunchesApplicationThroughApplicationUseCase() async {
        let application = AppDescriptor(
            name: "Demo",
            url: URL(fileURLWithPath: "/Applications/Demo.app")
        )
        let launcher = StubApplicationLauncher()
        let viewModel = LauncherViewModel(
            discoverApplications: DiscoverApplications(
                catalog: StubAppCatalog(descriptors: [])
            ),
            launchApplication: LaunchApplication(launcher: launcher)
        )

        await viewModel.launch(application)?.value

        XCTAssertEqual(launcher.launchedApplications, [application])
    }

    /// 面板收起后启动仍在后台进行（冷启动可能要数秒）：此时重新呼出面板启动其他应用，不能被前一次启动挡住。
    func testViewModelLaunchesAgainWhileEarlierLaunchIsInFlight() async {
        let first = AppDescriptor(name: "First", url: URL(fileURLWithPath: "/Applications/First.app"))
        let second = AppDescriptor(name: "Second", url: URL(fileURLWithPath: "/Applications/Second.app"))
        let launcher = StubApplicationLauncher()
        let viewModel = LauncherViewModel(
            discoverApplications: DiscoverApplications(catalog: StubAppCatalog(descriptors: [])),
            launchApplication: LaunchApplication(launcher: launcher)
        )

        let firstLaunch = viewModel.launch(first)
        let secondLaunch = viewModel.launch(second)
        await firstLaunch?.value
        await secondLaunch?.value

        XCTAssertEqual(launcher.launchedApplications.map(\.name).sorted(), ["First", "Second"])
    }

    func testViewModelPublishesLoadedStateAfterDiscovery() async {
        let viewModel = makeViewModel(with: [])

        await viewModel.loadApps()?.value

        XCTAssertEqual(viewModel.loadState, .loaded)
    }

    func testViewModelPublishesDiscoveryFailure() async {
        let viewModel = LauncherViewModel(
            discoverApplications: DiscoverApplications(catalog: ThrowingAppCatalog()),
            launchApplication: LaunchApplication(launcher: StubApplicationLauncher())
        )

        await viewModel.loadApps()?.value

        XCTAssertEqual(viewModel.errorMessage, "无法加载应用列表：目录不可用")
        XCTAssertEqual(viewModel.loadState, .failed("无法加载应用列表：目录不可用"))
    }

    /// 启动在后台进行、面板已经收起：失败经系统通知告知，不在面板上显示横幅。
    func testViewModelNotifiesLaunchFailure() async {
        let application = AppDescriptor(
            name: "Demo",
            url: URL(fileURLWithPath: "/Applications/Demo.app")
        )
        let notifier = MemoryUserNotifier()
        let viewModel = LauncherViewModel(
            discoverApplications: DiscoverApplications(catalog: StubAppCatalog(descriptors: [])),
            launchApplication: LaunchApplication(launcher: ThrowingApplicationLauncher()),
            notifier: notifier
        )

        await viewModel.launch(application)?.value

        XCTAssertEqual(notifier.records, [MemoryUserNotifier.Record(title: "无法启动 Demo", body: "启动失败")])
        XCTAssertNil(viewModel.launchErrorMessage)
    }

    /// 回归测试：失败横幅的高度计入面板展开高度，不能挤压结果行；失败状态清除后高度复原。
    func testViewModelReservesPanelHeightForLaunchErrorBanner() async {
        let application = AppDescriptor(
            name: "Demo",
            url: URL(fileURLWithPath: "/Applications/Demo.app")
        )
        let viewModel = makeViewModel(with: [application])
        await viewModel.loadApps()?.value
        viewModel.query = "Demo"

        viewModel.publishFileOpenError(fileName: "Demo", reason: "文件已被移动或删除")

        XCTAssertEqual(
            viewModel.panelHeight,
            LauncherLayout.totalHeight(isExpanded: true, content: .results(rowCount: 1, hasLaunchError: true))
        )

        viewModel.query = "Dem"
        XCTAssertNil(viewModel.launchErrorMessage)
        XCTAssertEqual(
            viewModel.panelHeight,
            LauncherLayout.totalHeight(isExpanded: true, content: .results(rowCount: 1))
        )
    }

    // MARK: - 索引搜索与使用历史

    func testViewModelSearchesThroughIndexWithInitialsAndAliases() async {
        let vsCode = AppDescriptor(
            name: "Visual Studio Code",
            url: URL(fileURLWithPath: "/Applications/Visual Studio Code.app"),
            bundleIdentifier: "com.example.editor"
        )
        let viewModel = makeViewModel(
            with: [vsCode],
            aliases: ["com.example.editor": ["vscode"]]
        )
        await viewModel.loadApps()?.value

        viewModel.query = "vsc"
        XCTAssertEqual(viewModel.filteredApps.map(\.name), ["Visual Studio Code"])

        viewModel.query = "vscode"
        XCTAssertEqual(viewModel.filteredApps.map(\.name), ["Visual Studio Code"])
    }

    func testViewModelRecordsUsageOnlyAfterSuccessfulLaunch() async {
        let application = AppDescriptor(
            name: "Demo",
            url: URL(fileURLWithPath: "/Applications/Demo.app"),
            bundleIdentifier: "com.example.demo"
        )
        let store = MemoryAppUsageStore()
        let viewModel = LauncherViewModel(
            discoverApplications: DiscoverApplications(catalog: StubAppCatalog(descriptors: [])),
            launchApplication: LaunchApplication(launcher: StubApplicationLauncher()),
            usageStore: store
        )

        await viewModel.launch(application)?.value
        let successfulRecord = await pollUsageRecord(store: store, key: application.usageKey)
        XCTAssertEqual(successfulRecord?.launchCount, 1)

        let failingViewModel = LauncherViewModel(
            discoverApplications: DiscoverApplications(catalog: StubAppCatalog(descriptors: [])),
            launchApplication: LaunchApplication(launcher: ThrowingApplicationLauncher()),
            usageStore: store
        )
        await failingViewModel.launch(application)?.value
        let failedRecord = await pollUsageRecord(
            store: store,
            key: application.usageKey,
            expecting: 2
        )
        XCTAssertEqual(failedRecord?.launchCount, 1)
    }

    func testViewModelIgnoresUsageRankingAndRecordingWhenDisabled() async {
        let alphaOne = AppDescriptor(
            name: "AlphaOne",
            url: URL(fileURLWithPath: "/Applications/AlphaOne.app"),
            bundleIdentifier: "com.example.alphaone"
        )
        let alphaTwo = AppDescriptor(
            name: "AlphaTwo",
            url: URL(fileURLWithPath: "/Applications/AlphaTwo.app"),
            bundleIdentifier: "com.example.alphatwo"
        )
        let store = MemoryAppUsageStore()
        let settingsStore = MemoryAppSettingsStore()
        let viewModel = LauncherViewModel(
            discoverApplications: DiscoverApplications(
                catalog: StubAppCatalog(descriptors: [alphaOne, alphaTwo])
            ),
            launchApplication: LaunchApplication(launcher: StubApplicationLauncher()),
            usageStore: store,
            settingsStore: settingsStore
        )
        await viewModel.loadApps()?.value

        // 记录 AlphaTwo 的启动历史后，同级前缀匹配内历史置顶。
        await viewModel.launch(alphaTwo)?.value
        let record = await pollUsageRecord(store: store, key: alphaTwo.usageKey)
        XCTAssertEqual(record?.launchCount, 1)

        await viewModel.refreshApplications(force: true)?.value
        viewModel.query = "alpha"
        XCTAssertEqual(viewModel.filteredApps.map(\.name), ["AlphaTwo", "AlphaOne"])

        // 关闭启动历史排序：不重新扫描也应对下一次按键检索立即生效，且不再记录新的启动。
        settingsStore.save(AppSettings(isUsageRankingEnabled: false))
        viewModel.query = "alpha"
        XCTAssertEqual(viewModel.filteredApps.map(\.name), ["AlphaOne", "AlphaTwo"])

        await viewModel.launch(alphaOne)?.value
        let unrecorded = await pollUsageRecord(store: store, key: alphaOne.usageKey, expecting: 0)
        XCTAssertNil(unrecorded)

        // 重新开启后恢复记录。
        settingsStore.save(AppSettings())
        await viewModel.launch(alphaOne)?.value
        let reRecorded = await pollUsageRecord(store: store, key: alphaOne.usageKey)
        XCTAssertEqual(reRecorded?.launchCount, 1)
    }

    func testViewModelRefreshesSnapshotOnlyWhenStale() async {
        let apps = [
            AppDescriptor(name: "Alpha", url: URL(fileURLWithPath: "/Applications/Alpha.app"))
        ]
        let counter = ScanCounter()
        let holder = DateHolder()
        let viewModel = LauncherViewModel(
            discoverApplications: DiscoverApplications(
                catalog: CountingAppCatalog(descriptors: apps, counter: counter)
            ),
            launchApplication: LaunchApplication(launcher: StubApplicationLauncher()),
            now: { holder.date }
        )

        await viewModel.loadApps()?.value
        XCTAssertEqual(counter.count, 1)

        XCTAssertNil(viewModel.refreshApplications(force: false))
        XCTAssertEqual(counter.count, 1)

        holder.date = holder.date.addingTimeInterval(601)
        let refresh = viewModel.refreshApplications(force: false)
        XCTAssertNotNil(refresh)
        await refresh?.value
        XCTAssertEqual(counter.count, 2)
        XCTAssertEqual(viewModel.apps, apps)
    }

    func testViewModelForcedRefreshReplacesSnapshotWithLatestScan() async {
        let first = [AppDescriptor(name: "Alpha", url: URL(fileURLWithPath: "/Applications/Alpha.app"))]
        let second = [
            AppDescriptor(name: "Alpha", url: URL(fileURLWithPath: "/Applications/Alpha.app")),
            AppDescriptor(name: "Beta", url: URL(fileURLWithPath: "/Applications/Beta.app"))
        ]
        let viewModel = LauncherViewModel(
            discoverApplications: DiscoverApplications(
                catalog: SequencedAppCatalog(results: [first, second])
            ),
            launchApplication: LaunchApplication(launcher: StubApplicationLauncher())
        )

        await viewModel.loadApps()?.value
        XCTAssertEqual(viewModel.apps.map(\.name), ["Alpha"])

        await viewModel.refreshApplications(force: true)?.value
        XCTAssertEqual(viewModel.apps.map(\.name), ["Alpha", "Beta"])
    }

    /// 回归测试：后台目录刷新完成时，选中的结果仍在就保持选中与操作菜单，不把用户拉回第一项；
    /// 选中的应用已不在时才归零并滚回顶部。
    func testBackgroundRefreshKeepsSelectionWhileSelectedResultRemains() async {
        let safari = AppDescriptor(name: "Safari", url: URL(fileURLWithPath: "/Applications/Safari.app"))
        let preview = AppDescriptor(
            name: "Safari Technology Preview",
            url: URL(fileURLWithPath: "/Applications/Safari Technology Preview.app")
        )
        let viewModel = LauncherViewModel(
            discoverApplications: DiscoverApplications(
                catalog: SequencedAppCatalog(results: [[safari, preview], [safari, preview], [safari]])
            ),
            launchApplication: LaunchApplication(launcher: StubApplicationLauncher())
        )
        await viewModel.loadApps()?.value
        viewModel.query = "safari"
        viewModel.moveSelection(by: 1)
        viewModel.toggleActionSheet()
        let resetRequest = viewModel.listResetRequest

        await viewModel.refreshApplications(force: true)?.value

        XCTAssertEqual(viewModel.selectedApp?.name, "Safari Technology Preview")
        XCTAssertTrue(viewModel.isActionSheetVisible)
        XCTAssertEqual(viewModel.listResetRequest, resetRequest)

        await viewModel.refreshApplications(force: true)?.value

        XCTAssertEqual(viewModel.selectedIndex, 0)
        XCTAssertEqual(viewModel.selectedApp?.name, "Safari")
        XCTAssertFalse(viewModel.isActionSheetVisible)
        XCTAssertGreaterThan(viewModel.listResetRequest, resetRequest)
    }

    /// 回归测试：空扫描结果（如目录临时异常）不得清空使用历史。
    func testViewModelKeepsUsageHistoryWhenScanReturnsEmpty() async {
        let demo = AppDescriptor(
            name: "Demo",
            url: URL(fileURLWithPath: "/Applications/Demo.app"),
            bundleIdentifier: "com.example.demo"
        )
        let store = MemoryAppUsageStore()
        await store.recordLaunch(key: demo.usageKey)

        let viewModel = LauncherViewModel(
            discoverApplications: DiscoverApplications(
                catalog: SequencedAppCatalog(results: [[demo], []])
            ),
            launchApplication: LaunchApplication(launcher: StubApplicationLauncher()),
            usageStore: store
        )

        await viewModel.loadApps()?.value
        await viewModel.refreshApplications(force: true)?.value

        let record = await store.records()[demo.usageKey]
        XCTAssertNotNil(record)
        XCTAssertEqual(record?.launchCount, 1)
    }

    // MARK: - 网址直达

    func testViewModelRecognizesWebURLAsFirstResult() async {
        let app = AppDescriptor(name: "Safari", url: URL(fileURLWithPath: "/Applications/Safari.app"))
        let viewModel = makeViewModel(with: [app])
        await viewModel.loadApps()?.value

        viewModel.query = "github.com"

        XCTAssertEqual(
            viewModel.results.first,
            .webURL(URL(string: "https://github.com")!)
        )
        XCTAssertEqual(
            viewModel.selectedResult,
            .webURL(URL(string: "https://github.com")!)
        )
        XCTAssertNil(viewModel.selectedApp)
    }

    /// 回归测试：网址直达行存在时按列表高度展开，不塌缩成状态页（与快速查询行同一守卫）。
    func testViewModelExpandsToListHeightWhenWebURLRecognizedWithoutOtherResults() async {
        let app = AppDescriptor(name: "Safari", url: URL(fileURLWithPath: "/Applications/Safari.app"))
        let viewModel = makeViewModel(with: [app])
        await viewModel.loadApps()?.value

        viewModel.query = "github.com"

        XCTAssertEqual(viewModel.webURLResult, URL(string: "https://github.com"))
        XCTAssertTrue(viewModel.filteredApps.isEmpty)
        XCTAssertEqual(
            viewModel.panelHeight,
            LauncherLayout.totalHeight(isExpanded: true, content: .results(rowCount: 1))
        )
    }

    /// 回归测试：扫描应用目录期间网址行仍视为结果，expandedContent 不得返回 .status，
    /// 否则窗口按结果高度展开而视图渲染加载转轮，网址行被遮蔽。
    func testViewModelKeepsWebURLResultsWhileCatalogIsLoading() async {
        let viewModel = makeViewModel(with: [])

        // 不等待扫描完成，制造“正在加载应用”窗口。
        let loadTask = viewModel.loadApps()
        viewModel.query = "github.com"

        XCTAssertNil(viewModel.quickQueryResult)
        XCTAssertEqual(viewModel.webURLResult, URL(string: "https://github.com"))
        XCTAssertTrue(viewModel.isLoading)
        XCTAssertTrue(viewModel.apps.isEmpty)
        XCTAssertEqual(viewModel.expandedContent, .results(rowCount: 1))
        XCTAssertEqual(viewModel.results, [.webURL(URL(string: "https://github.com")!)])

        await loadTask?.value
        XCTAssertEqual(viewModel.expandedContent, .results(rowCount: 1))
    }

    /// 回归测试：目录扫描失败时网址行仍是可直达结果，不得被“重试”错误页遮蔽。
    func testViewModelKeepsWebURLResultsWhenCatalogScanFails() async {
        let viewModel = LauncherViewModel(
            discoverApplications: DiscoverApplications(catalog: ThrowingAppCatalog()),
            launchApplication: LaunchApplication(launcher: StubApplicationLauncher())
        )

        await viewModel.loadApps()?.value
        viewModel.query = "github.com"

        XCTAssertNotNil(viewModel.errorMessage)
        XCTAssertTrue(viewModel.apps.isEmpty)
        XCTAssertNil(viewModel.quickQueryResult)
        XCTAssertEqual(viewModel.webURLResult, URL(string: "https://github.com"))
        XCTAssertEqual(viewModel.expandedContent, .results(rowCount: 1))
        XCTAssertEqual(viewModel.results.first, .webURL(URL(string: "https://github.com")!))
    }

    func testViewModelDoesNotRecognizePlainQueriesAsWebURL() async {
        let app = AppDescriptor(name: "Safari", url: URL(fileURLWithPath: "/Applications/Safari.app"))
        let viewModel = makeViewModel(with: [app])
        await viewModel.loadApps()?.value

        viewModel.query = "saf"

        XCTAssertNil(viewModel.webURLResult)
        XCTAssertEqual(viewModel.selectedApp, app)
    }

    func testViewModelOpensWebURLThroughURLOpener() async {
        let opener = StubURLOpener()
        let viewModel = LauncherViewModel(
            discoverApplications: DiscoverApplications(catalog: StubAppCatalog(descriptors: [])),
            launchApplication: LaunchApplication(launcher: StubApplicationLauncher()),
            openURL: OpenURL(opener: opener)
        )

        await viewModel.open(.webURL(URL(string: "https://github.com")!))?.value

        XCTAssertEqual(opener.openedURLs, [URL(string: "https://github.com")!])
    }

    func testViewModelSearchWebOpensSearchURLAndIgnoresEmptyQuery() async {
        let opener = StubURLOpener()
        let viewModel = LauncherViewModel(
            discoverApplications: DiscoverApplications(catalog: StubAppCatalog(descriptors: [])),
            launchApplication: LaunchApplication(launcher: StubApplicationLauncher()),
            openURL: OpenURL(opener: opener)
        )
        await viewModel.loadApps()?.value

        viewModel.query = "   "
        XCTAssertNil(viewModel.searchWeb())
        XCTAssertEqual(opener.openedURLs, [])

        viewModel.query = "swift arrays"
        await viewModel.searchWeb()?.value
        XCTAssertEqual(opener.openedURLs, [WebSearchEngine.bing.searchURL(for: "swift arrays")])
    }

    func testViewModelSearchWebUsesSearchEngineFromSettings() async {
        let opener = StubURLOpener()
        let viewModel = makeViewModel(
            with: [],
            settingsStore: MemoryAppSettingsStore(initial: AppSettings(webSearchEngine: .baidu)),
            urlOpener: OpenURL(opener: opener)
        )
        await viewModel.loadApps()?.value

        viewModel.query = "swift arrays"
        await viewModel.searchWeb()?.value

        XCTAssertEqual(opener.openedURLs, [WebSearchEngine.baidu.searchURL(for: "swift arrays")])
    }

    // MARK: - 动作面板

    func testActionSheetToggleNavigationAndDismissal() async {
        let app = AppDescriptor(name: "TestApp", url: URL(fileURLWithPath: "/Applications/TestApp.app"), bundleIdentifier: "com.test.app")
        let viewModel = makeViewModel(with: [app])
        await viewModel.loadApps()?.value
        viewModel.query = "Test"

        XCTAssertEqual(viewModel.results.count, 1)
        XCTAssertFalse(viewModel.isActionSheetVisible)

        // Toggle on
        viewModel.toggleActionSheet()
        XCTAssertTrue(viewModel.isActionSheetVisible)
        XCTAssertEqual(viewModel.selectedActionIndex, 0)
        XCTAssertEqual(viewModel.selectedAction, .revealInFinder)

        // Navigate down
        viewModel.moveActionSelection(by: 1)
        XCTAssertEqual(viewModel.selectedActionIndex, 1)
        XCTAssertEqual(viewModel.selectedAction, .copyPath)

        viewModel.moveActionSelection(by: 1)
        XCTAssertEqual(viewModel.selectedActionIndex, 2)
        XCTAssertEqual(viewModel.selectedAction, .copyBundleID)

        viewModel.moveActionSelection(by: 1)
        XCTAssertEqual(viewModel.selectedActionIndex, 3)
        XCTAssertEqual(viewModel.selectedAction, .openInTerminal)

        // Wrap around down
        viewModel.moveActionSelection(by: 1)
        XCTAssertEqual(viewModel.selectedActionIndex, 0)

        // Wrap around up
        viewModel.moveActionSelection(by: -1)
        XCTAssertEqual(viewModel.selectedActionIndex, 3)

        // Dismiss
        viewModel.dismissActionSheet()
        XCTAssertFalse(viewModel.isActionSheetVisible)
    }

    func testActionSheetAutoDismissesOnQueryOrSelectionChange() async {
        let app1 = AppDescriptor(name: "AppOne", url: URL(fileURLWithPath: "/Applications/AppOne.app"))
        let app2 = AppDescriptor(name: "AppTwo", url: URL(fileURLWithPath: "/Applications/AppTwo.app"))
        let viewModel = makeViewModel(with: [app1, app2])
        await viewModel.loadApps()?.value
        viewModel.query = "App"

        viewModel.toggleActionSheet()
        XCTAssertTrue(viewModel.isActionSheetVisible)

        // Selection move dismisses action sheet
        viewModel.moveSelection(by: 1)
        XCTAssertFalse(viewModel.isActionSheetVisible)

        viewModel.toggleActionSheet()
        XCTAssertTrue(viewModel.isActionSheetVisible)

        // Query change dismisses action sheet
        viewModel.query = "AppO"
        XCTAssertFalse(viewModel.isActionSheetVisible)
    }

    // MARK: - Helpers

    private func pollUsageRecord(
        store: MemoryAppUsageStore,
        key: String,
        expecting launchCount: Int = 1
    ) async -> AppUsageRecord? {
        for _ in 0..<100 {
            let record = await store.records()[key]
            if record?.launchCount == launchCount { return record }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return await store.records()[key]
    }
}
