import AppKit
import Foundation
import XCTest

@testable import OI

@MainActor
final class QuickLookPresenterTests: XCTestCase {
    // MARK: - QuickLookPresenter

    func testQuickLookPresenterReloadUpdatesPreviewURLWhenActive() {
        let presenter = QuickLookPresenter()
        let url1 = URL(fileURLWithPath: "/tmp/test1.txt")
        let url2 = URL(fileURLWithPath: "/tmp/test2.txt")

        presenter.show(url: url1)
        XCTAssertTrue(presenter.isActive)
        XCTAssertEqual(presenter.currentPreviewURL, url1)

        presenter.reloadPreviewItem(with: url2)
        XCTAssertEqual(presenter.currentPreviewURL, url2)

        presenter.reloadPreviewItem(with: nil)
        XCTAssertNil(presenter.currentPreviewURL)

        presenter.close()
        XCTAssertFalse(presenter.isActive)
        XCTAssertNil(presenter.currentPreviewURL)
    }

    func testQuickLookPresenterReloadIgnoredWhenInactive() {
        let presenter = QuickLookPresenter()
        let url = URL(fileURLWithPath: "/tmp/test.txt")

        presenter.reloadPreviewItem(with: url)
        XCTAssertFalse(presenter.isActive)
        XCTAssertNil(presenter.currentPreviewURL)
    }

    func testQuickLookPresenterEndControlDoesNotDeactivateSession() {
        let presenter = QuickLookPresenter()
        let url = URL(fileURLWithPath: "/tmp/test.txt")
        presenter.show(url: url)
        XCTAssertTrue(presenter.isActive)

        presenter.endControl()
        XCTAssertTrue(presenter.isActive)
        XCTAssertEqual(presenter.currentPreviewURL, url)

        presenter.close()
        XCTAssertFalse(presenter.isActive)
        XCTAssertNil(presenter.currentPreviewURL)
    }

    func testQuickLookPresenterForwardsEventsViaDelegate() {
        let presenter = QuickLookPresenter()
        var receivedKeyCode: UInt16?
        presenter.onHandleEvent = { event in
            receivedKeyCode = event.keyCode
            return true
        }

        let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "",
            charactersIgnoringModifiers: "",
            isARepeat: false,
            keyCode: 125
        )!

        let handled = presenter.previewPanel(nil, handle: event)
        XCTAssertTrue(handled)
        XCTAssertEqual(receivedKeyCode, 125)
    }

    func testQuickLookPresenterWindowWillCloseEndsSession() {
        let presenter = QuickLookPresenter()
        let url = URL(fileURLWithPath: "/tmp/test.txt")
        presenter.show(url: url)
        XCTAssertTrue(presenter.isActive)

        presenter.windowWillClose(Notification(name: NSWindow.willCloseNotification))
        XCTAssertFalse(presenter.isActive)
        XCTAssertNil(presenter.currentPreviewURL)
    }

    // MARK: - 与面板控制器集成

    func testLauncherPanelControllerHandlesQuickLookDelegateEvents() async throws {
        let tempDir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let file1 = tempDir.appendingPathComponent("App1.app")
        let file2 = tempDir.appendingPathComponent("App2.app")
        FileManager.default.createFile(atPath: file1.path, contents: Data("1".utf8))
        FileManager.default.createFile(atPath: file2.path, contents: Data("2".utf8))

        let app1 = AppDescriptor(name: "App1", url: file1)
        let app2 = AppDescriptor(name: "App2", url: file2)
        let viewModel = makeViewModel(with: [app1, app2])
        let controller = LauncherPanelController(
            viewModel: viewModel,
            iconProvider: WorkspaceApplicationIconProvider()
        )
        defer { controller.stop() }
        controller.show()
        await viewModel.loadApps()?.value
        viewModel.query = "App"

        let cmdYEvent = try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [.command],
                timestamp: 1,
                windowNumber: 0,
                context: nil,
                characters: "y",
                charactersIgnoringModifiers: "y",
                isARepeat: false,
                keyCode: 16
            )
        )
        _ = controller.handleKeyDown(cmdYEvent)
        XCTAssertTrue(controller.quickLook.isActive)
        XCTAssertEqual(controller.quickLook.currentPreviewURL, file1)

        let downArrowEvent = try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [],
                timestamp: 2,
                windowNumber: 0,
                context: nil,
                characters: "",
                charactersIgnoringModifiers: "",
                isARepeat: false,
                keyCode: 125
            )
        )
        let handled = controller.quickLook.previewPanel(nil, handle: downArrowEvent)
        XCTAssertTrue(handled)
        XCTAssertEqual(viewModel.selectedIndex, 1)
        XCTAssertEqual(controller.quickLook.currentPreviewURL, file2)
    }

    func testLauncherPanelResignKeyHidesWhenFocusLeavesAppEvenIfQuickLookIsActive() throws {
        let viewModel = makeViewModel(with: [])
        let controller = LauncherPanelController(
            viewModel: viewModel,
            iconProvider: WorkspaceApplicationIconProvider()
        )
        defer { controller.stop() }
        controller.show()
        XCTAssertTrue(controller.isVisible)

        controller.quickLook.show(url: URL(fileURLWithPath: "/tmp/test.txt"))
        XCTAssertTrue(controller.quickLook.isActive)

        controller.panel.resignKey()

        XCTAssertTrue(controller.isDismissalInProgress || !controller.isVisible)
    }

    func testQuickLookPanelDismissesWhenApplicationResignsActive() throws {
        let viewModel = makeViewModel(with: [])
        let controller = LauncherPanelController(
            viewModel: viewModel,
            iconProvider: WorkspaceApplicationIconProvider()
        )
        defer { controller.stop() }
        controller.show()
        XCTAssertTrue(controller.isVisible)

        controller.quickLook.show(url: URL(fileURLWithPath: "/tmp/test.txt"))
        XCTAssertTrue(controller.quickLook.isActive)

        NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: NSApp)

        XCTAssertTrue(controller.isDismissalInProgress || !controller.isVisible)
    }

    func testLauncherPanelControllerArrowNavigationUpdatesQuickLookPreview() async throws {
        let tempDir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let file1 = tempDir.appendingPathComponent("App1.app")
        let file2 = tempDir.appendingPathComponent("App2.app")
        FileManager.default.createFile(atPath: file1.path, contents: Data("1".utf8))
        FileManager.default.createFile(atPath: file2.path, contents: Data("2".utf8))

        let app1 = AppDescriptor(name: "App1", url: file1)
        let app2 = AppDescriptor(name: "App2", url: file2)
        let viewModel = makeViewModel(with: [app1, app2])
        let controller = LauncherPanelController(
            viewModel: viewModel,
            iconProvider: WorkspaceApplicationIconProvider()
        )
        defer { controller.stop() }
        controller.show()
        await viewModel.loadApps()?.value
        viewModel.query = "App"
        XCTAssertEqual(viewModel.results.count, 2)
        XCTAssertEqual(viewModel.selectedIndex, 0)

        let cmdYEvent = try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [.command],
                timestamp: 10,
                windowNumber: 0,
                context: nil,
                characters: "y",
                charactersIgnoringModifiers: "y",
                isARepeat: false,
                keyCode: 16
            )
        )
        _ = controller.handleKeyDown(cmdYEvent)
        XCTAssertTrue(controller.quickLook.isActive)
        XCTAssertEqual(controller.quickLook.currentPreviewURL, file1)

        let downArrowEvent = try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [],
                timestamp: 11,
                windowNumber: 0,
                context: nil,
                characters: "",
                charactersIgnoringModifiers: "",
                isARepeat: false,
                keyCode: 125
            )
        )
        _ = controller.handleKeyDown(downArrowEvent)
        XCTAssertEqual(viewModel.selectedIndex, 1)
        XCTAssertEqual(controller.quickLook.currentPreviewURL, file2)
    }
}
