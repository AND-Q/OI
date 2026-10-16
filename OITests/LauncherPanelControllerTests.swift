import AppKit
import Foundation
import XCTest

@testable import OI

@MainActor
final class LauncherPanelControllerTests: XCTestCase {
    // MARK: - Escape 键

    func testLauncherPanelControllerEscapeClearsQueryWhenNotEmpty() throws {
        let viewModel = makeViewModel(with: [])
        let controller = LauncherPanelController(
            viewModel: viewModel,
            iconProvider: WorkspaceApplicationIconProvider()
        )
        defer { controller.stop() }

        controller.show()
        XCTAssertTrue(controller.isVisible)

        viewModel.query = "Safari"
        XCTAssertEqual(viewModel.query, "Safari")
        XCTAssertTrue(viewModel.isExpanded)

        let escapeEvent = try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: "\u{1b}",
                charactersIgnoringModifiers: "\u{1b}",
                isARepeat: false,
                keyCode: 53
            )
        )

        let handled = controller.handleKeyDown(escapeEvent)
        XCTAssertNil(handled)
        XCTAssertEqual(viewModel.query, "")
        XCTAssertFalse(viewModel.isExpanded)
        XCTAssertTrue(controller.isVisible)
        XCTAssertFalse(controller.isDismissalInProgress)
    }

    func testLauncherPanelControllerEscapeDismissesWhenQueryIsEmpty() throws {
        let viewModel = makeViewModel(with: [])
        let controller = LauncherPanelController(
            viewModel: viewModel,
            iconProvider: WorkspaceApplicationIconProvider()
        )
        defer { controller.stop() }

        controller.show()
        XCTAssertTrue(controller.isVisible)
        XCTAssertEqual(viewModel.query, "")

        let escapeEvent = try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: "\u{1b}",
                charactersIgnoringModifiers: "\u{1b}",
                isARepeat: false,
                keyCode: 53
            )
        )

        let handled = controller.handleKeyDown(escapeEvent)
        XCTAssertNil(handled)
        XCTAssertTrue(controller.isDismissalInProgress || !controller.isVisible)
    }

    // MARK: - 打开与显示

    func testLauncherPanelControllerOpenSucceedsAndDismisses() async throws {
        let app = AppDescriptor(name: "Demo", url: URL(fileURLWithPath: "/Applications/Demo.app"))
        let viewModel = makeViewModel(with: [app])
        let controller = LauncherPanelController(
            viewModel: viewModel,
            iconProvider: WorkspaceApplicationIconProvider()
        )
        defer { controller.stop() }

        controller.show()
        XCTAssertTrue(controller.isVisible)

        await controller.open(.application(app))?.value
        XCTAssertTrue(controller.isDismissalInProgress || !controller.isVisible)
    }

    /// 回车后立即收起面板，不等目标应用启动完成：打开任务尚未执行时面板已在淡出。
    func testLauncherPanelControllerOpenDismissesWithoutWaitingForLaunch() async throws {
        let app = AppDescriptor(name: "Demo", url: URL(fileURLWithPath: "/Applications/Demo.app"))
        let launcher = StubApplicationLauncher()
        let viewModel = LauncherViewModel(
            discoverApplications: DiscoverApplications(catalog: StubAppCatalog(descriptors: [app])),
            launchApplication: LaunchApplication(launcher: launcher)
        )
        let controller = LauncherPanelController(
            viewModel: viewModel,
            iconProvider: WorkspaceApplicationIconProvider()
        )
        defer { controller.stop() }

        controller.show()
        XCTAssertTrue(controller.isVisible)

        let launch = controller.open(.application(app))

        XCTAssertTrue(controller.isDismissalInProgress || !controller.isVisible)
        XCTAssertEqual(launcher.launchedApplications, [], "启动在后台进行，收起面板不等它")
        await launch?.value
        XCTAssertEqual(launcher.launchedApplications, [app])
    }

    /// 启动失败时面板照常收起，失败经系统通知告知。
    func testLauncherPanelControllerOpenFailureDismissesAndNotifies() async throws {
        let app = AppDescriptor(name: "Faulty", url: URL(fileURLWithPath: "/Applications/Faulty.app"))
        let notifier = MemoryUserNotifier()
        let viewModel = LauncherViewModel(
            discoverApplications: DiscoverApplications(catalog: StubAppCatalog(descriptors: [app])),
            launchApplication: LaunchApplication(launcher: ThrowingApplicationLauncher()),
            notifier: notifier
        )
        let controller = LauncherPanelController(
            viewModel: viewModel,
            iconProvider: WorkspaceApplicationIconProvider()
        )
        defer { controller.stop() }

        controller.show()
        XCTAssertTrue(controller.isVisible)

        await controller.open(.application(app))?.value

        XCTAssertTrue(controller.isDismissalInProgress || !controller.isVisible)
        XCTAssertEqual(notifier.records, [MemoryUserNotifier.Record(title: "无法启动 Faulty", body: "启动失败")])
        XCTAssertNil(viewModel.launchErrorMessage)
    }

    /// 面板淡出期间再按回车或单击结果都不再打开，避免手快连按重复启动。
    func testLauncherPanelControllerIgnoresRepeatedOpenWhileDismissing() async throws {
        let app = AppDescriptor(name: "Demo", url: URL(fileURLWithPath: "/Applications/Demo.app"))
        let launcher = StubApplicationLauncher()
        let viewModel = LauncherViewModel(
            discoverApplications: DiscoverApplications(catalog: StubAppCatalog(descriptors: [app])),
            launchApplication: LaunchApplication(launcher: launcher)
        )
        let controller = LauncherPanelController(
            viewModel: viewModel,
            iconProvider: WorkspaceApplicationIconProvider()
        )
        defer { controller.stop() }

        controller.show()
        await viewModel.loadApps()?.value
        viewModel.query = "Demo"
        XCTAssertNotNil(viewModel.selectedResult)

        let windowNumber = controller.panel.windowNumber
        XCTAssertNil(controller.handleKeyDown(try returnKeyEvent(timestamp: 1, windowNumber: windowNumber)))
        XCTAssertTrue(controller.isDismissalInProgress || !controller.isVisible)

        _ = controller.handleKeyDown(try returnKeyEvent(timestamp: 2, windowNumber: windowNumber))
        XCTAssertNil(controller.open(.application(app)))

        for _ in 0..<100 where launcher.launchedApplications.isEmpty {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(launcher.launchedApplications, [app])
    }

    func testLauncherPanelControllerRevealWebURLCopiesLinkAndDismisses() throws {
        let viewModel = makeViewModel(with: [])
        let controller = LauncherPanelController(
            viewModel: viewModel,
            iconProvider: WorkspaceApplicationIconProvider()
        )
        defer { controller.stop() }

        controller.show()
        XCTAssertTrue(controller.isVisible)

        controller.reveal(.webURL(URL(string: "https://github.com")!))

        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "https://github.com")
        XCTAssertTrue(controller.isDismissalInProgress || !controller.isVisible)
    }

    func testLauncherPanelControllerRevealFailsWhenFileDoesNotExist() throws {
        let viewModel = makeViewModel(with: [])
        let controller = LauncherPanelController(
            viewModel: viewModel,
            iconProvider: WorkspaceApplicationIconProvider()
        )
        defer { controller.stop() }

        controller.show()
        XCTAssertTrue(controller.isVisible)

        let nonexistent = SearchResult.file(
            FileDescriptor(
                name: "missing.txt",
                url: URL(fileURLWithPath: "/tmp/nonexistent_missing_\(UUID().uuidString).txt"),
                isDirectory: false
            )
        )

        controller.reveal(nonexistent)

        XCTAssertTrue(controller.isVisible)
        XCTAssertFalse(controller.isDismissalInProgress)
        XCTAssertEqual(viewModel.launchErrorMessage, "无法打开 missing.txt：文件已被移动或删除")
    }

    // MARK: - 快捷键

    func testLauncherPanelControllerCommandFRevealsSelectedResultAndDismisses() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let bundleURL = try makeApplicationBundle(
            directoryName: "RevealDemo.app",
            displayName: "RevealDemo",
            in: root
        )
        let app = AppDescriptor(name: "RevealDemo", url: bundleURL)
        let viewModel = makeViewModel(with: [app])
        let controller = LauncherPanelController(
            viewModel: viewModel,
            iconProvider: WorkspaceApplicationIconProvider()
        )
        defer { controller.stop() }

        controller.show()
        XCTAssertTrue(controller.isVisible)
        await viewModel.loadApps()?.value

        viewModel.query = "RevealDemo"
        XCTAssertNotNil(viewModel.selectedResult)

        let commandFEvent = try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [.command],
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: "f",
                charactersIgnoringModifiers: "f",
                isARepeat: false,
                keyCode: 3
            )
        )

        let handled = controller.handleKeyDown(commandFEvent)
        XCTAssertNil(handled)
        XCTAssertTrue(controller.isDismissalInProgress || !controller.isVisible)
    }

    func testLauncherPanelControllerCommandReturnSearchesWebAndDismisses() async throws {
        let opener = StubURLOpener()
        let app = AppDescriptor(name: "Demo", url: URL(fileURLWithPath: "/Applications/Demo.app"))
        let viewModel = makeViewModel(with: [app], urlOpener: OpenURL(opener: opener))
        let controller = LauncherPanelController(
            viewModel: viewModel,
            iconProvider: WorkspaceApplicationIconProvider()
        )
        defer { controller.stop() }

        controller.show()
        XCTAssertTrue(controller.isVisible)
        await viewModel.loadApps()?.value

        viewModel.query = "swift arrays"
        XCTAssertNil(viewModel.selectedApp)

        let commandReturnEvent = try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [.command],
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: "\r",
                charactersIgnoringModifiers: "\r",
                isARepeat: false,
                keyCode: 36
            )
        )

        let handled = controller.handleKeyDown(commandReturnEvent)
        XCTAssertNil(handled)

        for _ in 0..<100 where controller.isVisible && !controller.isDismissalInProgress {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(controller.isDismissalInProgress || !controller.isVisible)
        XCTAssertEqual(opener.openedURLs, [WebSearchEngine.bing.searchURL(for: "swift arrays")])
    }

    func testLauncherPanelControllerCommandReturnWithEmptyQueryDoesNothing() throws {
        let opener = StubURLOpener()
        let viewModel = makeViewModel(with: [], urlOpener: OpenURL(opener: opener))
        let controller = LauncherPanelController(
            viewModel: viewModel,
            iconProvider: WorkspaceApplicationIconProvider()
        )
        defer { controller.stop() }

        controller.show()
        XCTAssertTrue(controller.isVisible)
        XCTAssertEqual(viewModel.query, "")

        let commandReturnEvent = try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [.command],
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: "\r",
                charactersIgnoringModifiers: "\r",
                isARepeat: false,
                keyCode: 36
            )
        )

        let handled = controller.handleKeyDown(commandReturnEvent)
        XCTAssertNil(handled)
        XCTAssertEqual(opener.openedURLs, [])
        XCTAssertTrue(controller.isVisible)
        XCTAssertFalse(controller.isDismissalInProgress)
    }

    func testLauncherPanelControllerCommandReturnSearchWebFailureDismissesAndNotifies() async throws {
        let opener = ThrowingURLOpener()
        let notifier = MemoryUserNotifier()
        let viewModel = makeViewModel(with: [], urlOpener: OpenURL(opener: opener), notifier: notifier)
        let controller = LauncherPanelController(
            viewModel: viewModel,
            iconProvider: WorkspaceApplicationIconProvider()
        )
        defer { controller.stop() }

        controller.show()
        XCTAssertTrue(controller.isVisible)

        viewModel.query = "unmatched search term"
        XCTAssertTrue(viewModel.results.isEmpty)

        let commandReturnEvent = try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [.command],
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: "\r",
                charactersIgnoringModifiers: "\r",
                isARepeat: false,
                keyCode: 36
            )
        )

        let handled = controller.handleKeyDown(commandReturnEvent)
        XCTAssertNil(handled)
        XCTAssertTrue(controller.isDismissalInProgress || !controller.isVisible)

        for _ in 0..<100 where notifier.records.isEmpty {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTAssertEqual(notifier.records, [MemoryUserNotifier.Record(title: "无法打开链接", body: "无法打开浏览器")])
        XCTAssertNil(viewModel.launchErrorMessage)
    }

    func testLauncherPanelControllerReturnOpensSelectedResultAndDismisses() async throws {
        let app = AppDescriptor(name: "Demo", url: URL(fileURLWithPath: "/Applications/Demo.app"))
        let viewModel = makeViewModel(with: [app])
        let controller = LauncherPanelController(
            viewModel: viewModel,
            iconProvider: WorkspaceApplicationIconProvider()
        )
        defer { controller.stop() }

        controller.show()
        XCTAssertTrue(controller.isVisible)
        await viewModel.loadApps()?.value

        viewModel.query = "Demo"
        XCTAssertNotNil(viewModel.selectedResult)

        let returnEvent = try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: "\r",
                charactersIgnoringModifiers: "\r",
                isARepeat: false,
                keyCode: 36
            )
        )

        let handled = controller.handleKeyDown(returnEvent)
        XCTAssertNil(handled)

        // Launch completes asynchronously; wait for the panel to start dismissing.
        for _ in 0..<100 where controller.isVisible && !controller.isDismissalInProgress {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(controller.isDismissalInProgress || !controller.isVisible)
    }

    // MARK: - Helpers

    private func returnKeyEvent(timestamp: TimeInterval, windowNumber: Int) throws -> NSEvent {
        try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [],
                timestamp: timestamp,
                windowNumber: windowNumber,
                context: nil,
                characters: "\r",
                charactersIgnoringModifiers: "\r",
                isARepeat: false,
                keyCode: 36
            )
        )
    }
}
