import AppKit
import Foundation
import XCTest

@testable import OI

@MainActor
final class StatusBarControllerTests: XCTestCase {
    func testStatusBarControllerStartAttachesMenuWithItems() throws {
        var showLauncherCalled = false
        var settingsCalled = false
        var aboutCalled = false
        var checkForUpdatesCalled = false
        var quitCalled = false

        let controller = StatusBarController(
            onShowLauncher: { showLauncherCalled = true },
            onSettings: { settingsCalled = true },
            onAbout: { aboutCalled = true },
            onCheckForUpdates: { checkForUpdatesCalled = true },
            isCheckingForUpdates: { false },
            onQuit: { quitCalled = true }
        )
        defer { controller.stop() }

        controller.start()

        let statusItem = try XCTUnwrap(controller.statusItem)
        let button = try XCTUnwrap(statusItem.button)
        XCTAssertNotNil(button.image)

        // 菜单挂在状态项上，任何点按都会弹出菜单
        let menu = try XCTUnwrap(statusItem.menu)
        XCTAssertTrue(menu === controller.contextMenu)
        XCTAssertEqual(menu.items.count, 7)
        XCTAssertEqual(menu.items[0].title, "显示启动器")
        XCTAssertTrue(menu.items[0].target === controller)
        XCTAssertTrue(menu.items[1].isSeparatorItem)
        XCTAssertEqual(menu.items[2].title, "关于 OI")
        XCTAssertTrue(menu.items[2].target === controller)
        XCTAssertEqual(menu.items[3].title, "检查更新…")
        XCTAssertTrue(menu.items[3].target === controller)
        XCTAssertEqual(menu.items[4].title, "设置…")
        XCTAssertEqual(menu.items[4].keyEquivalent, ",")
        XCTAssertTrue(menu.items[4].target === controller)
        XCTAssertTrue(menu.items[5].isSeparatorItem)
        XCTAssertEqual(menu.items[6].title, "退出")
        XCTAssertEqual(menu.items[6].keyEquivalent, "q")
        XCTAssertTrue(menu.items[6].target === controller)

        // 触发各菜单项的动作
        _ = menu.items[0].target?.perform(menu.items[0].action, with: menu.items[0])
        XCTAssertTrue(showLauncherCalled)

        _ = menu.items[2].target?.perform(menu.items[2].action, with: menu.items[2])
        XCTAssertTrue(aboutCalled)

        _ = menu.items[3].target?.perform(menu.items[3].action, with: menu.items[3])
        XCTAssertTrue(checkForUpdatesCalled)

        _ = menu.items[4].target?.perform(menu.items[4].action, with: menu.items[4])
        XCTAssertTrue(settingsCalled)

        _ = menu.items[6].target?.perform(menu.items[6].action, with: menu.items[6])
        XCTAssertTrue(quitCalled)
    }

    /// 检查更新期间菜单项改为「正在检查更新…」且不可点按，结束后恢复；其他菜单项不受影响。
    func testCheckForUpdatesItemIsDisabledWhileChecking() throws {
        var isChecking = true
        let controller = StatusBarController(
            onShowLauncher: {},
            onSettings: {},
            onAbout: {},
            onCheckForUpdates: {},
            isCheckingForUpdates: { isChecking },
            onQuit: {}
        )
        defer { controller.stop() }
        controller.start()
        let menu = try XCTUnwrap(controller.contextMenu)
        let updateItem = menu.items[3]

        XCTAssertFalse(controller.validateMenuItem(updateItem))
        XCTAssertEqual(updateItem.title, "正在检查更新…")
        XCTAssertTrue(controller.validateMenuItem(menu.items[2]))

        isChecking = false
        XCTAssertTrue(controller.validateMenuItem(updateItem))
        XCTAssertEqual(updateItem.title, "检查更新…")
    }
}
