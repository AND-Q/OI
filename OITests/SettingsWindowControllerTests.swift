import AppKit
import Foundation
import XCTest

@testable import OI

@MainActor
final class SettingsWindowControllerTests: XCTestCase {
    // 窗口关闭后实例与 NSHostingController 常驻内存（isReleasedWhenClosed = false），
    // 再次展示时 SwiftUI 的 onAppear 未必重新触发，show() 必须主动同步登录项状态。
    func testShowSyncsLoginItemStatusOnCachedWindowPresentation() {
        let loginItems = StubLoginItemController()
        let viewModel = SettingsViewModel(
            settingsStore: MemoryAppSettingsStore(),
            loginItemController: loginItems
        )
        let controller = SettingsWindowController(viewModel: viewModel)
        defer {
            NSApplication.shared.windows.first { $0.title == "OI 设置" }?.close()
        }

        controller.show()
        XCTAssertFalse(viewModel.isLaunchAtLoginEnabled)

        // 模拟窗口关闭期间用户在系统设置中批准了登录项，重新呼出窗口应拿到新状态。
        loginItems.status = .requiresApproval
        controller.show()

        XCTAssertTrue(viewModel.isLaunchAtLoginEnabled)
        XCTAssertEqual(viewModel.launchAtLoginNotice, .approvalPending)
    }

    func testCloseOrdersOutPresentedWindow() throws {
        let viewModel = SettingsViewModel(
            settingsStore: MemoryAppSettingsStore(),
            loginItemController: StubLoginItemController()
        )
        let controller = SettingsWindowController(viewModel: viewModel)

        controller.show()
        let window = try XCTUnwrap(NSApplication.shared.windows.first { $0.title == "OI 设置" })
        XCTAssertTrue(window.isVisible)

        controller.close()
        XCTAssertFalse(window.isVisible)
    }
}

@MainActor
private final class StubLoginItemController: LoginItemControlling {
    var status: LoginItemStatus

    init(initialStatus: LoginItemStatus = .notRegistered) {
        status = initialStatus
    }

    func register() throws {}
    func unregister() throws {}
}
