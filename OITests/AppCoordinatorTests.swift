import AppKit
import Foundation
import XCTest

@testable import OI

@MainActor
final class AppCoordinatorTests: XCTestCase {
    /// 启动期按用户持久化的组合注册，并把面板 toggle 交给注册出的按键处理器。
    func testStartRegistersPersistedShortcutWithPanelHandler() throws {
        let shortcut = LauncherShortcut(keyCode: 2, modifiers: 1 << 8 | 1 << 12)
        let context = makeCoordinator(shortcut: shortcut, failing: false)
        defer { context.coordinator.stop() }

        context.coordinator.start()

        XCTAssertEqual(context.shortcutService.registeredShortcuts, [shortcut])
        XCTAssertNil(context.settingsViewModel.launcherShortcutNotice)
        XCTAssertNotNil(try XCTUnwrap(context.shortcutService.handler), "注册出的热键必须接管按键处理")
    }

    /// 组合被其他应用占用时保持未注册，并把失败原因同步到设置面板。
    func testStartReportsRegistrationFailureToSettings() {
        let shortcut = LauncherShortcut(keyCode: 2, modifiers: 1 << 8)
        let context = makeCoordinator(shortcut: shortcut, failing: true)
        defer { context.coordinator.stop() }

        context.coordinator.start()

        XCTAssertEqual(context.shortcutService.registeredShortcuts, [shortcut])
        XCTAssertEqual(
            context.settingsViewModel.launcherShortcutNotice,
            .failure("该快捷键已被其他应用占用")
        )
        // 设置值保持不变：用户能在设置面板看到原因并重新选择组合。
        XCTAssertEqual(context.settingsViewModel.settings.launcherShortcut, shortcut)
    }

    /// 文件搜索开启时启动期请求目录授权；关闭时不请求，之后在设置中开启时再请求。
    func testStartRequestsFolderAccessOnlyWhenFileSearchEnabled() {
        let enabled = makeCoordinator(shortcut: .standard, failing: false)
        defer { enabled.coordinator.stop() }
        enabled.coordinator.start()
        XCTAssertEqual(enabled.folderAccessRequests.count, 1)

        let disabled = makeCoordinator(shortcut: .standard, failing: false, isFileSearchEnabled: false)
        defer { disabled.coordinator.stop() }
        disabled.coordinator.start()
        XCTAssertEqual(disabled.folderAccessRequests.count, 0)

        disabled.settingsViewModel.settings.isFileSearchEnabled = true
        XCTAssertEqual(disabled.folderAccessRequests.count, 1)
    }

    // MARK: - Helpers

    private struct Context {
        let coordinator: AppCoordinator
        let settingsViewModel: SettingsViewModel
        let shortcutService: StubGlobalShortcutService
        let folderAccessRequests: RequestCounter
    }

    private final class RequestCounter {
        var count = 0
    }

    private func makeCoordinator(
        shortcut: LauncherShortcut,
        failing: Bool,
        isFileSearchEnabled: Bool = true
    ) -> Context {
        let shortcutService = StubGlobalShortcutService()
        if failing {
            shortcutService.registeredErrors[shortcut] = StubGlobalShortcutError(
                message: "该快捷键已被其他应用占用"
            )
        }
        // 默认设置即开启静默启动，启动过程不会自动呼出面板。
        let settingsStore = MemoryAppSettingsStore(
            initial: AppSettings(isFileSearchEnabled: isFileSearchEnabled, launcherShortcut: shortcut)
        )
        let settingsViewModel = SettingsViewModel(
            settingsStore: settingsStore,
            loginItemController: StubLoginItemController()
        )
        let folderAccessRequests = RequestCounter()
        let coordinator = AppCoordinator(
            dependencies: AppDependencies(
                launcherViewModel: makeViewModel(with: [], settingsStore: settingsStore),
                settingsViewModel: settingsViewModel,
                settingsStore: settingsStore,
                applicationIconProvider: StubApplicationIconProvider(),
                globalShortcutService: shortcutService,
                fileSearchAccessRequester: { folderAccessRequests.count += 1 }
            )
        )
        return Context(
            coordinator: coordinator,
            settingsViewModel: settingsViewModel,
            shortcutService: shortcutService,
            folderAccessRequests: folderAccessRequests
        )
    }
}

@MainActor
private final class StubGlobalShortcutService: GlobalShortcutHandling {
    private(set) var registeredShortcuts: [LauncherShortcut] = []
    private(set) var handler: (() -> Void)?
    /// 按组合注入的注册失败；未注入的组合视为注册成功。
    var registeredErrors: [LauncherShortcut: Error] = [:]

    func register(keyCode: UInt32, modifiers: UInt32, handler: @escaping () -> Void) throws {
        let shortcut = LauncherShortcut(keyCode: keyCode, modifiers: modifiers)
        registeredShortcuts.append(shortcut)
        if let error = registeredErrors[shortcut] {
            throw error
        }
        self.handler = handler
    }

    func unregister() {
        handler = nil
    }
}

private struct StubGlobalShortcutError: LocalizedError {
    let message: String

    var errorDescription: String? { message }
}

@MainActor
private final class StubApplicationIconProvider: ApplicationIconProviding {
    func icon(for url: URL) -> NSImage { NSImage() }
}

@MainActor
private final class StubLoginItemController: LoginItemControlling {
    var status: LoginItemStatus = .notRegistered

    func register() throws {}
    func unregister() throws {}
}
