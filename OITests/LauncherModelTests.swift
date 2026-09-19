import Combine
import Foundation
import XCTest

@testable import OI

@MainActor
final class LauncherModelTests: XCTestCase {
    func testAppDescriptorNormalizesURLAndUsesItAsIdentity() {
        let rawURL = URL(fileURLWithPath: "/tmp/OITests/../OITests/Demo.app")
        let descriptor = AppDescriptor(name: "Demo", url: rawURL)

        XCTAssertEqual(descriptor.url, rawURL.standardizedFileURL)
        XCTAssertEqual(descriptor.id, descriptor.url.path)
        XCTAssertEqual(descriptor.id, rawURL.standardizedFileURL.path)
    }

    func testFileSystemAppCatalogReturnsEmptyForEmptyDirectory() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let catalog = FileSystemAppCatalog(searchDirectories: [root])
        let descriptors = try await catalog.scan()

        XCTAssertTrue(descriptors.isEmpty)
    }

    func testFileSystemAppCatalogSortsDescriptorsByDisplayName() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        try makeApplicationBundle(directoryName: "zeta.app", displayName: "Zeta", in: root)
        try makeApplicationBundle(directoryName: "alpha.app", displayName: "Alpha", in: root)
        try makeApplicationBundle(directoryName: "beta.app", displayName: "Beta", in: root)

        let catalog = FileSystemAppCatalog(searchDirectories: [root])
        let descriptors = try await catalog.scan()

        XCTAssertEqual(descriptors.map(\.name), ["Alpha", "Beta", "Zeta"])
    }

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
        XCTAssertFalse(viewModel.isLaunching)
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

    func testViewModelPublishesLaunchFailure() async {
        let application = AppDescriptor(
            name: "Demo",
            url: URL(fileURLWithPath: "/Applications/Demo.app")
        )
        let viewModel = LauncherViewModel(
            discoverApplications: DiscoverApplications(catalog: StubAppCatalog(descriptors: [])),
            launchApplication: LaunchApplication(launcher: ThrowingApplicationLauncher())
        )

        await viewModel.launch(application)?.value

        XCTAssertEqual(viewModel.launchErrorMessage, "无法启动 Demo：启动失败")
        XCTAssertEqual(viewModel.launchState, .failed("无法启动 Demo：启动失败"))
    }

    func testFileSystemAppCatalogReadsBundleIdentifier() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        try makeApplicationBundle(
            directoryName: "demo.app",
            displayName: "Demo",
            bundleIdentifier: "com.example.demo",
            in: root
        )

        let catalog = FileSystemAppCatalog(searchDirectories: [root])
        let descriptors = try await catalog.scan()

        XCTAssertEqual(descriptors.first?.bundleIdentifier, "com.example.demo")
    }

    func testFileSystemAppCatalogKeepsShallowerPathForSameBundleIdentifier() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        try makeApplicationBundle(
            directoryName: "nested/Demo.app",
            displayName: "Demo",
            bundleIdentifier: "com.example.demo",
            in: root
        )
        try makeApplicationBundle(
            directoryName: "Demo.app",
            displayName: "Demo",
            bundleIdentifier: "com.example.demo",
            in: root
        )

        let catalog = FileSystemAppCatalog(searchDirectories: [root])
        let descriptors = try await catalog.scan()

        XCTAssertEqual(descriptors.count, 1)
        XCTAssertEqual(descriptors.first?.url.path, root.appendingPathComponent("Demo.app").path)
    }

    func testFileSystemAppCatalogDeduplicatesSymlinkedBundles() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let realURL = try makeApplicationBundle(
            directoryName: "Real.app",
            displayName: "Real",
            in: root
        )
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("Link.app", isDirectory: true),
            withDestinationURL: realURL
        )

        let catalog = FileSystemAppCatalog(searchDirectories: [root])
        let descriptors = try await catalog.scan()

        XCTAssertEqual(descriptors.count, 1)
        XCTAssertEqual(descriptors.first?.url, realURL)
    }

    func testFileSystemAppCatalogSkipsAppsNestedInsideOtherApps() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        try makeApplicationBundle(directoryName: "Outer.app", displayName: "Outer", in: root)
        try makeApplicationBundle(
            directoryName: "Outer.app/Contents/Inner.app",
            displayName: "Inner",
            in: root
        )

        let catalog = FileSystemAppCatalog(searchDirectories: [root])
        let descriptors = try await catalog.scan()

        XCTAssertEqual(descriptors.map(\.name), ["Outer"])
    }

    func testFileSystemAppCatalogSupportsDirectBundlePathInSearchDirectories() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let directAppURL = try makeApplicationBundle(
            directoryName: "Direct.app",
            displayName: "Direct",
            in: root
        )

        let catalog = FileSystemAppCatalog(searchDirectories: [directAppURL])
        let descriptors = try await catalog.scan()

        XCTAssertEqual(descriptors.count, 1)
        XCTAssertEqual(descriptors.first?.name, "Direct")
        XCTAssertEqual(descriptors.first?.url, directAppURL.standardizedFileURL)
    }

    func testFileSystemAppCatalogReadsLocalizedInfoPlistStrings() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let bundleURL = root.appendingPathComponent("WeChat.app", isDirectory: true)
        let contentsURL = bundleURL.appendingPathComponent("Contents", isDirectory: true)
        let resourcesURL = contentsURL.appendingPathComponent("Resources/zh-Hans.lproj", isDirectory: true)
        try FileManager.default.createDirectory(at: resourcesURL, withIntermediateDirectories: true)

        let info: [String: Any] = [
            "CFBundleDisplayName": "WeChat",
            "CFBundleName": "WeChat",
            "CFBundlePackageType": "APPL"
        ]
        let infoData = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try infoData.write(to: contentsURL.appendingPathComponent("Info.plist"))

        let localizedStrings = "\"CFBundleDisplayName\" = \"微信\";\n\"CFBundleName\" = \"微信\";\n"
        try localizedStrings.write(
            to: resourcesURL.appendingPathComponent("InfoPlist.strings"),
            atomically: true,
            encoding: .utf8
        )

        let catalog = FileSystemAppCatalog(searchDirectories: [root])
        let descriptors = try await catalog.scan()

        XCTAssertEqual(descriptors.first?.name, "微信")
    }

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

    func testNativeSearchInputSynchronizesEditingAndProgrammaticClear() {
        let input = LauncherSearchInputView()
        var changes: [String] = []
        input.onQueryChange = { changes.append($0) }
        input.update(query: "we", focusRequest: 0)
        XCTAssertEqual(input.textField.stringValue, "we")
        XCTAssertTrue(changes.isEmpty)

        input.textField.stringValue = "微信"
        input.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: input.textField))
        XCTAssertEqual(changes, ["微信"])

        input.update(query: "", focusRequest: 1)
        XCTAssertEqual(input.textField.stringValue, "")
        XCTAssertEqual(changes, ["微信"])
    }

    func testNativeSearchInputSubmitsThroughItsAction() throws {
        let input = LauncherSearchInputView()
        var submissions = 0
        input.onSubmit = { submissions += 1 }
        let action = try XCTUnwrap(input.textField.action)
        XCTAssertTrue(input.textField.sendAction(action, to: input.textField.target))
        XCTAssertEqual(submissions, 1)
        XCTAssertFalse(try XCTUnwrap(input.textField.cell).sendsActionOnEndEditing)
    }

    func testNativeSearchInputPreservesMarkedTextDuringUpdates() throws {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 58),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        let input = LauncherSearchInputView()
        panel.contentView = input
        panel.contentView?.layoutSubtreeIfNeeded()
        XCTAssertTrue(panel.makeFirstResponder(input.textField))
        let editor = try XCTUnwrap(input.textField.currentEditor() as? NSTextView)
        defer { panel.makeFirstResponder(nil) }
        editor.setMarkedText("wei", selectedRange: NSRange(location: 3, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(editor.hasMarkedText())

        input.update(query: "", focusRequest: 0)
        XCTAssertTrue(editor.hasMarkedText())
        XCTAssertEqual(editor.string, "wei")

        var submissions = 0
        input.onSubmit = { submissions += 1 }
        let action = try XCTUnwrap(input.textField.action)
        input.textField.sendAction(action, to: input.textField.target)
        XCTAssertEqual(submissions, 0)
    }

    func testPanelAnimationCoordinatorComputesExpectedSpotlightFrame() {
        let screen = NSScreen.main
        let frame = PanelAnimationCoordinator.frame(for: screen, height: LauncherLayout.searchHeight)
        let visibleFrame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)

        XCTAssertEqual(frame.width, LauncherLayout.width)
        XCTAssertEqual(frame.height, LauncherLayout.searchHeight)
        XCTAssertEqual(frame.midX, visibleFrame.midX, accuracy: 1.0)
        XCTAssertEqual(frame.maxY, (visibleFrame.maxY - 156).rounded(), accuracy: 1.0)
        XCTAssertGreaterThanOrEqual(frame.minY, visibleFrame.minY)
        XCTAssertLessThanOrEqual(frame.maxY, visibleFrame.maxY)
    }

    func testCompactSurfaceUsesTopViewportOfExpandedGlass() {
        let hostedContent = NSView(frame: .zero)
        let surface = LauncherPanelSurface(
            contentView: hostedContent,
            cornerRadius: LauncherLayout.compactCornerRadius
        )
        surface.frame = NSRect(
            x: 0,
            y: 0,
            width: LauncherLayout.width,
            height: LauncherLayout.searchHeight
        )
        surface.layoutSubtreeIfNeeded()

        guard let glassView = surface.subviews.first as? NSGlassEffectView,
              let contentContainer = glassView.contentView else {
            return XCTFail("Expected the launcher surface to contain a glass viewport")
        }

        let expandedHeight = LauncherLayout.totalHeight(
            isExpanded: true,
            content: .results(rowCount: LauncherLayout.maximumVisibleRows)
        )
        XCTAssertEqual(glassView.frame.height, expandedHeight)
        XCTAssertEqual(glassView.frame.maxY, surface.bounds.maxY)
        XCTAssertEqual(hostedContent.frame.size, surface.bounds.size)
        XCTAssertEqual(hostedContent.frame.maxY, contentContainer.bounds.maxY)
    }

    func testClearingQueryBeforeFirstAnimationFrameCancelsExpansion() {
        let panel = LauncherPanel(
            contentRect: NSRect(x: 0, y: 0, width: LauncherLayout.width, height: LauncherLayout.searchHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        let animation = PanelAnimationCoordinator(
            panel: panel,
            initialHeight: LauncherLayout.searchHeight,
            reduceMotion: { false }
        )
        defer { animation.stopAnimations() }

        let expandedHeight = LauncherLayout.totalHeight(isExpanded: true, content: .results(rowCount: 7))
        animation.resize(toHeight: expandedHeight)
        XCTAssertEqual(animation.targetHeight, expandedHeight)
        XCTAssertEqual(animation.currentHeight, LauncherLayout.searchHeight)

        animation.resize(toHeight: LauncherLayout.searchHeight)
        XCTAssertEqual(animation.targetHeight, LauncherLayout.searchHeight)
        XCTAssertEqual(panel.frame.height, LauncherLayout.searchHeight)
    }

    func testReducedMotionResizesPanelAndGlassImmediately() {
        let panel = LauncherPanel(
            contentRect: NSRect(x: 0, y: 0, width: LauncherLayout.width, height: LauncherLayout.searchHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        let surface = LauncherPanelSurface(
            contentView: NSView(frame: NSRect(origin: .zero, size: panel.frame.size)),
            cornerRadius: LauncherLayout.compactCornerRadius
        )
        panel.contentView = surface
        let animation = PanelAnimationCoordinator(
            panel: panel,
            initialHeight: LauncherLayout.searchHeight,
            reduceMotion: { true }
        )

        let expandedHeight = LauncherLayout.totalHeight(isExpanded: true, content: .results(rowCount: 7))
        animation.resize(toHeight: expandedHeight)
        XCTAssertEqual(panel.frame.height, expandedHeight)
        XCTAssertEqual(animation.currentHeight, expandedHeight)
        XCTAssertEqual(surface.cornerRadius, LauncherLayout.expandedCornerRadius)

        let topEdge = panel.frame.maxY
        animation.resize(toHeight: LauncherLayout.searchHeight)
        XCTAssertEqual(panel.frame.height, LauncherLayout.searchHeight)
        XCTAssertEqual(animation.currentHeight, LauncherLayout.searchHeight)
        XCTAssertEqual(surface.cornerRadius, LauncherLayout.compactCornerRadius)
        XCTAssertEqual(panel.frame.maxY, topEdge)

        animation.fadeIn()
        XCTAssertEqual(panel.alphaValue, 1)
        animation.fadeOutAndOrderOut()
        XCTAssertFalse(panel.isVisible)
        XCTAssertFalse(animation.isDismissalInProgress)
        XCTAssertEqual(panel.alphaValue, 1)
    }

    func testScreenClosedBoundaryCheckIncludesScreenMaxBoundaries() {
        let screenRect = NSRect(x: 0, y: 0, width: 1470, height: 956)
        let topEdgePoint = NSPoint(x: 500, y: 956)
        let rightEdgePoint = NSPoint(x: 1470, y: 500)

        // NSRect.contains fails on max boundaries due to half-open interval
        XCTAssertFalse(screenRect.contains(topEdgePoint))
        XCTAssertFalse(screenRect.contains(rightEdgePoint))

        // Closed-boundary check correctly includes all 4 edges
        let containsPoint: (NSRect, NSPoint) -> Bool = { frame, point in
            point.x >= frame.minX && point.x <= frame.maxX
                && point.y >= frame.minY && point.y <= frame.maxY
        }
        XCTAssertTrue(containsPoint(screenRect, topEdgePoint))
        XCTAssertTrue(containsPoint(screenRect, rightEdgePoint))
        XCTAssertTrue(containsPoint(screenRect, NSPoint(x: 0, y: 500)))
        XCTAssertTrue(containsPoint(screenRect, NSPoint(x: 500, y: 0)))
        XCTAssertFalse(containsPoint(screenRect, NSPoint(x: 500, y: 956.1)))
        XCTAssertFalse(containsPoint(screenRect, NSPoint(x: 1470.1, y: 500)))
    }

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

    private func makeViewModel(
        with descriptors: [AppDescriptor],
        aliases: [String: [String]] = [:],
        usageStore: any AppUsageStoring = MemoryAppUsageStore(),
        now: @escaping () -> Date = { Date() }
    ) -> LauncherViewModel {
        LauncherViewModel(
            discoverApplications: DiscoverApplications(
                catalog: StubAppCatalog(descriptors: descriptors)
            ),
            launchApplication: LaunchApplication(
                launcher: StubApplicationLauncher()
            ),
            usageStore: usageStore,
            aliases: aliases,
            now: now
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OITests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @discardableResult
    private func makeApplicationBundle(
        directoryName: String,
        displayName: String,
        bundleIdentifier: String? = nil,
        in root: URL
    ) throws -> URL {
        let bundleURL = root.appendingPathComponent(directoryName, isDirectory: true)
        let contentsURL = bundleURL.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contentsURL, withIntermediateDirectories: true)

        var info: [String: Any] = [
            "CFBundleDisplayName": displayName,
            "CFBundleName": displayName,
            "CFBundlePackageType": "APPL"
        ]
        if let bundleIdentifier {
            info["CFBundleIdentifier"] = bundleIdentifier
        }
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try data.write(to: contentsURL.appendingPathComponent("Info.plist"))
        return bundleURL
    }
}

private struct StubAppCatalog: AppCatalog {
    let descriptors: [AppDescriptor]

    func scan() async throws -> [AppDescriptor] {
        try Task.checkCancellation()
        return descriptors
    }
}

private struct CountingAppCatalog: AppCatalog {
    let descriptors: [AppDescriptor]
    let counter: ScanCounter

    func scan() async throws -> [AppDescriptor] {
        counter.increment()
        return descriptors
    }
}

private final class SequencedAppCatalog: AppCatalog, @unchecked Sendable {
    private let results: [[AppDescriptor]]
    private let lock = NSLock()
    private var scans = 0

    init(results: [[AppDescriptor]]) {
        self.results = results
    }

    func scan() async throws -> [AppDescriptor] {
        let index = lock.withLock {
            let index = scans
            scans += 1
            return index
        }
        try? await Task.sleep(nanoseconds: 200_000_000)
        guard index < results.count else { return results.last ?? [] }
        return results[index]
    }
}

private final class ScanCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var countValue = 0

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return countValue
    }

    func increment() {
        lock.lock()
        countValue += 1
        lock.unlock()
    }
}

private final class DateHolder {
    var date = Date(timeIntervalSinceReferenceDate: 0)
}

private struct ThrowingAppCatalog: AppCatalog {
    enum CatalogError: LocalizedError {
        case unavailable

        var errorDescription: String? { "目录不可用" }
    }

    func scan() async throws -> [AppDescriptor] {
        throw CatalogError.unavailable
    }
}

@MainActor
private final class StubApplicationLauncher: ApplicationLaunching {
    private(set) var launchedApplications: [AppDescriptor] = []

    func launch(_ application: AppDescriptor) async throws {
        launchedApplications.append(application)
    }
}

@MainActor
private final class ThrowingApplicationLauncher: ApplicationLaunching {
    enum LaunchError: LocalizedError {
        case failed

        var errorDescription: String? { "启动失败" }
    }

    func launch(_ application: AppDescriptor) async throws {
        throw LaunchError.failed
    }
}
