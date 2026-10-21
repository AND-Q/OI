import AppKit
import Foundation
import XCTest

@testable import OI

// MARK: - Cmd+K 动作菜单与“在终端打开”

@MainActor
final class LauncherActionMenuTests: XCTestCase {
    func testSearchResultTerminalDirectoryFollowsResultKind() {
        let app = SearchResult.application(
            AppDescriptor(name: "Safari", url: URL(fileURLWithPath: "/Applications/Safari.app"))
        )
        XCTAssertEqual(app.terminalDirectory?.path, "/Applications")

        let folder = SearchResult.file(
            FileDescriptor(name: "工具", url: URL(fileURLWithPath: "/Users/demo/工具"), isDirectory: true)
        )
        XCTAssertEqual(folder.terminalDirectory?.path, "/Users/demo/工具")

        let file = SearchResult.file(
            FileDescriptor(name: "notes.txt", url: URL(fileURLWithPath: "/Users/demo/notes.txt"), isDirectory: false)
        )
        XCTAssertEqual(file.terminalDirectory?.path, "/Users/demo")

        let quickQuery = SearchResult.quickQuery(.calculation(expression: "1+1", value: "2"))
        XCTAssertNil(quickQuery.terminalDirectory)

        let webURL = SearchResult.webURL(URL(string: "https://example.com")!)
        XCTAssertNil(webURL.terminalDirectory)
    }

    func testAvailableActionsMatchResultCapabilities() {
        let app = SearchResult.application(
            AppDescriptor(
                name: "Safari",
                url: URL(fileURLWithPath: "/Applications/Safari.app"),
                bundleIdentifier: "com.apple.Safari"
            )
        )
        XCTAssertEqual(
            LauncherActionMenu.availableActions(for: app),
            [.revealInFinder, .copyPath, .copyBundleID, .openInTerminal]
        )

        let appWithoutBundleID = SearchResult.application(
            AppDescriptor(name: "Unknown", url: URL(fileURLWithPath: "/Applications/Unknown.app"))
        )
        XCTAssertEqual(
            LauncherActionMenu.availableActions(for: appWithoutBundleID),
            [.revealInFinder, .copyPath, .openInTerminal]
        )

        let file = SearchResult.file(
            FileDescriptor(name: "notes.txt", url: URL(fileURLWithPath: "/Users/demo/notes.txt"), isDirectory: false)
        )
        XCTAssertEqual(
            LauncherActionMenu.availableActions(for: file),
            [.revealInFinder, .copyPath, .openInTerminal, .openWith]
        )

        let folder = SearchResult.file(
            FileDescriptor(name: "工具", url: URL(fileURLWithPath: "/Users/demo/工具"), isDirectory: true)
        )
        XCTAssertEqual(
            LauncherActionMenu.availableActions(for: folder),
            [.revealInFinder, .copyPath, .openInTerminal, .openWith]
        )

        let quickQuery = SearchResult.quickQuery(.calculation(expression: "1+1", value: "2"))
        XCTAssertTrue(LauncherActionMenu.availableActions(for: quickQuery).isEmpty)

        let webURL = SearchResult.webURL(URL(string: "https://example.com")!)
        XCTAssertTrue(LauncherActionMenu.availableActions(for: webURL).isEmpty)
    }

    func testResultMenuActionMetadata() {
        XCTAssertEqual(ResultMenuAction.revealInFinder.title, "在 Finder 中显示")
        XCTAssertEqual(ResultMenuAction.revealInFinder.systemImage, "folder")
        XCTAssertEqual(ResultMenuAction.revealInFinder.shortcutKeys, ["⌘", "F"])

        XCTAssertEqual(ResultMenuAction.copyPath.title, "复制路径")
        XCTAssertEqual(ResultMenuAction.copyPath.systemImage, "doc.on.doc")
        XCTAssertEqual(ResultMenuAction.copyPath.shortcutKeys, ["⌥", "⌘", "C"])

        XCTAssertEqual(ResultMenuAction.copyBundleID.title, "复制 Bundle ID")
        XCTAssertEqual(ResultMenuAction.copyBundleID.systemImage, "number")
        XCTAssertEqual(ResultMenuAction.copyBundleID.shortcutKeys, ["⌘", "B"])

        XCTAssertEqual(ResultMenuAction.openInTerminal.title, "在终端中打开")
        XCTAssertEqual(ResultMenuAction.openInTerminal.systemImage, "terminal")
        XCTAssertEqual(ResultMenuAction.openInTerminal.shortcutKeys, ["⌘", "T"])

        XCTAssertEqual(ResultMenuAction.openWith.title, "用其他 App 打开…")
        XCTAssertEqual(ResultMenuAction.openWith.systemImage, "arrow.up.forward.app")
        XCTAssertEqual(ResultMenuAction.openWith.shortcutKeys, [])
    }

    // MARK: - 在终端打开

    func testPerformMenuActionOpenInTerminalFailsWhenDirectoryDoesNotExist() throws {
        let viewModel = makeViewModel(with: [])
        let controller = LauncherPanelController(
            viewModel: viewModel,
            iconProvider: WorkspaceApplicationIconProvider()
        )
        defer { controller.stop() }
        controller.show()

        let nonExistentResult = SearchResult.file(
            FileDescriptor(
                name: "missing.txt",
                url: URL(fileURLWithPath: "/tmp/non-existent-\(UUID().uuidString)/missing.txt"),
                isDirectory: false
            )
        )

        controller.performMenuAction(.openInTerminal, for: nonExistentResult)

        guard case .failed(let message) = viewModel.launchState else {
            XCTFail("Expected launchState to be failed")
            return
        }
        XCTAssertTrue(message.contains("文件已被移动或删除"))
        XCTAssertTrue(controller.isVisible)
        XCTAssertFalse(controller.isDismissalInProgress)
    }

    func testPerformMenuActionOpenWithFailsWhenFileDoesNotExist() throws {
        let viewModel = makeViewModel(with: [])
        let controller = LauncherPanelController(
            viewModel: viewModel,
            iconProvider: WorkspaceApplicationIconProvider()
        )
        defer { controller.stop() }
        controller.show()

        let nonExistentResult = SearchResult.file(
            FileDescriptor(
                name: "missing.md",
                url: URL(fileURLWithPath: "/tmp/non-existent-\(UUID().uuidString)/missing.md"),
                isDirectory: false
            )
        )

        controller.performMenuAction(.openWith, for: nonExistentResult)

        guard case .failed(let message) = viewModel.launchState else {
            XCTFail("Expected launchState to be failed")
            return
        }
        XCTAssertTrue(message.contains("文件已被移动或删除"))
        XCTAssertTrue(controller.isVisible)
    }

    func testPerformMenuActionOpenInTerminalSucceedsWhenDirectoryExists() throws {
        let tempDir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let viewModel = makeViewModel(with: [])
        let controller = LauncherPanelController(
            viewModel: viewModel,
            iconProvider: WorkspaceApplicationIconProvider()
        )
        defer { controller.stop() }
        controller.show()

        let validResult = SearchResult.file(
            FileDescriptor(name: "folder", url: tempDir, isDirectory: true)
        )

        controller.performMenuAction(.openInTerminal, for: validResult)

        XCTAssertTrue(controller.isDismissalInProgress || !controller.isVisible)
    }

    // MARK: - 控制器按键处理

    func testLauncherPanelControllerActionMenuKeyHandling() async throws {
        let tempDir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let app = AppDescriptor(name: "DemoApp", url: tempDir, bundleIdentifier: "com.demo.app")
        let viewModel = makeViewModel(with: [app])
        let controller = LauncherPanelController(
            viewModel: viewModel,
            iconProvider: WorkspaceApplicationIconProvider()
        )
        defer { controller.stop() }
        controller.show()
        await viewModel.loadApps()?.value
        viewModel.query = "Demo"

        // Cmd+K toggles action sheet on
        let cmdKEvent = try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [.command],
                timestamp: 10,
                windowNumber: 0,
                context: nil,
                characters: "k",
                charactersIgnoringModifiers: "k",
                isARepeat: false,
                keyCode: 40 // kVK_ANSI_K
            )
        )
        _ = controller.handleKeyDown(cmdKEvent)
        XCTAssertTrue(viewModel.isActionSheetVisible)
        XCTAssertEqual(viewModel.selectedActionIndex, 0)

        // Down arrow moves selection in action sheet
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
                keyCode: 125 // kVK_DownArrow
            )
        )
        _ = controller.handleKeyDown(downArrowEvent)
        XCTAssertTrue(viewModel.isActionSheetVisible)
        XCTAssertEqual(viewModel.selectedActionIndex, 1)

        // Escape closes action sheet, keeping panel open
        let escapeEvent = try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [],
                timestamp: 12,
                windowNumber: 0,
                context: nil,
                characters: "",
                charactersIgnoringModifiers: "",
                isARepeat: false,
                keyCode: 53 // kVK_Escape
            )
        )
        _ = controller.handleKeyDown(escapeEvent)
        XCTAssertFalse(viewModel.isActionSheetVisible)
        XCTAssertTrue(controller.isVisible)
        XCTAssertFalse(controller.isDismissalInProgress)
    }

    // MARK: - 复制路径快捷键

    func testOptionCommandCCopiesPathForFileResult() async throws {
        let app = AppDescriptor(name: "PathApp", url: URL(fileURLWithPath: "/Applications/PathApp.app"), bundleIdentifier: "com.test.pathapp")
        let viewModel = makeViewModel(with: [app])
        let controller = LauncherPanelController(
            viewModel: viewModel,
            iconProvider: WorkspaceApplicationIconProvider()
        )
        defer { controller.stop() }
        controller.show()
        await viewModel.loadApps()?.value
        viewModel.query = "Path"

        let event = try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [.command, .option],
                timestamp: 13,
                windowNumber: 0,
                context: nil,
                characters: "ç",
                charactersIgnoringModifiers: "c",
                isARepeat: false,
                keyCode: 8 // kVK_ANSI_C
            )
        )
        XCTAssertNil(controller.handleKeyDown(event))
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "/Applications/PathApp.app")
        XCTAssertTrue(controller.isDismissalInProgress || !controller.isVisible)
    }

    func testOptionCommandCIgnoresWebURLResult() throws {
        let viewModel = makeViewModel(with: [])
        let controller = LauncherPanelController(
            viewModel: viewModel,
            iconProvider: WorkspaceApplicationIconProvider()
        )
        defer { controller.stop() }
        controller.show()
        viewModel.query = "https://github.com"
        XCTAssertEqual(viewModel.selectedResult, .webURL(URL(string: "https://github.com")!))

        let event = try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [.command, .option],
                timestamp: 14,
                windowNumber: 0,
                context: nil,
                characters: "ç",
                charactersIgnoringModifiers: "c",
                isARepeat: false,
                keyCode: 8 // kVK_ANSI_C
            )
        )
        // 网址结果没有可复制的文件路径：事件原样放行，面板保持打开。
        XCTAssertNotNil(controller.handleKeyDown(event))
        XCTAssertTrue(controller.isVisible)
        XCTAssertFalse(controller.isDismissalInProgress)
    }
}
