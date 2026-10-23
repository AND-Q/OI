import AppKit
import Foundation
import SwiftUI
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
        let controller = SettingsWindowController(viewModel: viewModel, setActivationPolicy: { _ in })
        defer {
            settingsWindow()?.close()
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
        let controller = SettingsWindowController(viewModel: viewModel, setActivationPolicy: { _ in })

        controller.show()
        let window = try XCTUnwrap(settingsWindow())
        XCTAssertTrue(window.isVisible)

        controller.close()
        XCTAssertFalse(window.isVisible)
    }

    // 菜单栏应用的窗口被其他应用盖住后无从切回：打开期间作为普通应用，关闭后恢复为菜单栏应用。
    func testWindowShowsAsRegularAppWhileOpen() {
        var policies: [NSApplication.ActivationPolicy] = []
        let controller = SettingsWindowController(
            viewModel: SettingsViewModel(
                settingsStore: MemoryAppSettingsStore(),
                loginItemController: StubLoginItemController()
            ),
            setActivationPolicy: { policies.append($0) }
        )

        controller.show()
        XCTAssertEqual(policies, [.regular])

        controller.show()
        controller.close()
        XCTAssertEqual(policies, [.regular, .regular, .accessory], "再次呼出保持普通应用，关闭后恢复")
    }

    /// 窗口标题随当前分类变化，按托管的设置页查找窗口。
    private func settingsWindow() -> NSWindow? {
        NSApplication.shared.windows.first { $0.contentViewController is NSHostingController<SettingsView> }
    }
}
