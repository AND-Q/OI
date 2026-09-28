import AppKit
import Foundation
import XCTest

@testable import OI

@MainActor
final class StatusBarControllerTests: XCTestCase {
    func testStatusBarControllerStartConfiguresButtonAndMenu() throws {
        var toggleCalled = false
        var aboutCalled = false
        var quitCalled = false

        let controller = StatusBarController(
            onToggle: { toggleCalled = true },
            onAbout: { aboutCalled = true },
            onQuit: { quitCalled = true }
        )
        defer { controller.stop() }

        controller.start()

        let statusItem = try XCTUnwrap(controller.statusItem)
        let button = try XCTUnwrap(statusItem.button)
        XCTAssertNotNil(button.image)
        XCTAssertTrue(button.target === controller)
        XCTAssertEqual(button.action, #selector(StatusBarController.handleStatusItemClick(_:)))

        // Menu is prepared but not attached to statusItem yet (so clicks go to button)
        XCTAssertNil(statusItem.menu)
        let menu = try XCTUnwrap(controller.contextMenu)
        XCTAssertEqual(menu.items.count, 3)
        XCTAssertEqual(menu.items[0].title, "关于 OI")
        XCTAssertTrue(menu.items[0].target === controller)
        XCTAssertTrue(menu.items[1].isSeparatorItem)
        XCTAssertEqual(menu.items[2].title, "退出")
        XCTAssertEqual(menu.items[2].keyEquivalent, "q")
        XCTAssertTrue(menu.items[2].target === controller)

        // Trigger menu item actions
        _ = menu.items[0].target?.perform(menu.items[0].action, with: menu.items[0])
        XCTAssertTrue(aboutCalled)

        _ = menu.items[2].target?.perform(menu.items[2].action, with: menu.items[2])
        XCTAssertTrue(quitCalled)
    }

    func testStatusBarControllerLeftClickTogglesLauncher() throws {
        var toggleCount = 0
        let controller = StatusBarController(
            onToggle: { toggleCount += 1 },
            onAbout: {},
            onQuit: {}
        )
        defer { controller.stop() }
        controller.start()

        let leftClickEvent = try XCTUnwrap(
            NSEvent.mouseEvent(
                with: .leftMouseUp,
                location: .zero,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                eventNumber: 0,
                clickCount: 1,
                pressure: 1.0
            )
        )

        controller.handleStatusItemClick(with: leftClickEvent)
        XCTAssertEqual(toggleCount, 1)
        XCTAssertNil(controller.statusItem?.menu)

        // Nil event fallback also triggers toggle
        controller.handleStatusItemClick(with: nil)
        XCTAssertEqual(toggleCount, 2)
    }

    func testStatusBarControllerRightClickPresentsMenuAndMenuCloseResetsIt() throws {
        var toggleCount = 0
        let controller = StatusBarController(
            onToggle: { toggleCount += 1 },
            onAbout: {},
            onQuit: {}
        )
        defer { controller.stop() }
        controller.start()

        let rightClickEvent = try XCTUnwrap(
            NSEvent.mouseEvent(
                with: .rightMouseUp,
                location: .zero,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                eventNumber: 0,
                clickCount: 1,
                pressure: 1.0
            )
        )

        controller.handleStatusItemClick(with: rightClickEvent)
        XCTAssertEqual(toggleCount, 0)
        XCTAssertNotNil(controller.statusItem?.menu)
        XCTAssertTrue(controller.statusItem?.menu === controller.contextMenu)

        // Closing the menu schedules clearing statusItem.menu on the next main runloop tick
        let menu = try XCTUnwrap(controller.contextMenu)
        controller.menuDidClose(menu)

        let exp = expectation(description: "Menu cleared on next tick")
        DispatchQueue.main.async {
            XCTAssertNil(controller.statusItem?.menu)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1.0)
    }

    func testStatusBarControllerControlLeftClickTreatedAsRightClick() throws {
        var toggleCount = 0
        let controller = StatusBarController(
            onToggle: { toggleCount += 1 },
            onAbout: {},
            onQuit: {}
        )
        defer { controller.stop() }
        controller.start()

        let controlLeftClickEvent = try XCTUnwrap(
            NSEvent.mouseEvent(
                with: .leftMouseUp,
                location: .zero,
                modifierFlags: [.control],
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                eventNumber: 0,
                clickCount: 1,
                pressure: 1.0
            )
        )

        controller.handleStatusItemClick(with: controlLeftClickEvent)
        XCTAssertEqual(toggleCount, 0)
        XCTAssertNotNil(controller.statusItem?.menu)
        XCTAssertTrue(controller.statusItem?.menu === controller.contextMenu)
    }
}
