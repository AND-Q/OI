import Foundation
import XCTest

@testable import OI

final class LauncherShortcutTests: XCTestCase {
    func testStandardIsOptionPlusSpace() {
        // 49 = kVK_Space，1 << 11 = optionKey（Carbon 掩码）。
        XCTAssertEqual(LauncherShortcut.standard.keyCode, 49)
        XCTAssertEqual(LauncherShortcut.standard.modifiers, 1 << 11)
    }

    func testDefaultSettingsUseStandardShortcut() {
        XCTAssertEqual(AppSettings().launcherShortcut, .standard)
    }

    func testIsValidRequiresActionableModifier() {
        XCTAssertTrue(LauncherShortcut(keyCode: 49, modifiers: 1 << 8).isValid) // ⌘
        XCTAssertTrue(LauncherShortcut(keyCode: 49, modifiers: 1 << 11).isValid) // ⌥
        XCTAssertTrue(LauncherShortcut(keyCode: 49, modifiers: 1 << 12).isValid) // ⌃
        XCTAssertTrue(LauncherShortcut(keyCode: 49, modifiers: 1 << 8 | 1 << 9).isValid) // ⌘⇧
        XCTAssertFalse(LauncherShortcut(keyCode: 49, modifiers: 0).isValid)
        XCTAssertFalse(LauncherShortcut(keyCode: 49, modifiers: 1 << 9).isValid) // 仅 ⇧
        XCTAssertFalse(LauncherShortcut(keyCode: 49, modifiers: 1 << 10).isValid) // 仅 ⇪
    }
}
