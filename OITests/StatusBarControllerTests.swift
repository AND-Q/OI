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
        var quitCalled = false

        let controller = StatusBarController(
            onShowLauncher: { showLauncherCalled = true },
            onSettings: { settingsCalled = true },
            onAbout: { aboutCalled = true },
            onQuit: { quitCalled = true }
        )
        defer { controller.stop() }

        controller.start()

        let statusItem = try XCTUnwrap(controller.statusItem)
        let button = try XCTUnwrap(statusItem.button)
        XCTAssertNotNil(button.image)

        // Menu is attached to the status item so any click presents it
        let menu = try XCTUnwrap(statusItem.menu)
        XCTAssertTrue(menu === controller.contextMenu)
        XCTAssertEqual(menu.items.count, 6)
        XCTAssertEqual(menu.items[0].title, "显示启动器")
        XCTAssertTrue(menu.items[0].target === controller)
        XCTAssertTrue(menu.items[1].isSeparatorItem)
        XCTAssertEqual(menu.items[2].title, "关于 OI")
        XCTAssertTrue(menu.items[2].target === controller)
        XCTAssertEqual(menu.items[3].title, "设置…")
        XCTAssertEqual(menu.items[3].keyEquivalent, ",")
        XCTAssertTrue(menu.items[3].target === controller)
        XCTAssertTrue(menu.items[4].isSeparatorItem)
        XCTAssertEqual(menu.items[5].title, "退出")
        XCTAssertEqual(menu.items[5].keyEquivalent, "q")
        XCTAssertTrue(menu.items[5].target === controller)

        // Trigger menu item actions
        _ = menu.items[0].target?.perform(menu.items[0].action, with: menu.items[0])
        XCTAssertTrue(showLauncherCalled)

        _ = menu.items[2].target?.perform(menu.items[2].action, with: menu.items[2])
        XCTAssertTrue(aboutCalled)

        _ = menu.items[3].target?.perform(menu.items[3].action, with: menu.items[3])
        XCTAssertTrue(settingsCalled)

        _ = menu.items[5].target?.perform(menu.items[5].action, with: menu.items[5])
        XCTAssertTrue(quitCalled)
    }
}
