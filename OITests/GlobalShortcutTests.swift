import Foundation
import XCTest

@testable import OI

final class GlobalShortcutTests: XCTestCase {
    func testDefaultLauncherIsOptionPlusSpace() {
        // 49 = kVK_Space，1 << 11 = optionKey（Carbon 掩码）。
        XCTAssertEqual(GlobalShortcut.defaultLauncher.keyCode, 49)
        XCTAssertEqual(GlobalShortcut.defaultLauncher.modifiers, 1 << 11)
    }

    func testDefaultSettingsUseDefaultLauncherShortcut() {
        XCTAssertEqual(AppSettings().launcherShortcut, .defaultLauncher)
    }

    func testIsValidRequiresActionableModifier() {
        XCTAssertTrue(GlobalShortcut(keyCode: 49, modifiers: 1 << 8).isValid) // ⌘
        XCTAssertTrue(GlobalShortcut(keyCode: 49, modifiers: 1 << 11).isValid) // ⌥
        XCTAssertTrue(GlobalShortcut(keyCode: 49, modifiers: 1 << 12).isValid) // ⌃
        XCTAssertTrue(GlobalShortcut(keyCode: 49, modifiers: 1 << 8 | 1 << 9).isValid) // ⌘⇧
        XCTAssertFalse(GlobalShortcut(keyCode: 49, modifiers: 0).isValid)
        XCTAssertFalse(GlobalShortcut(keyCode: 49, modifiers: 1 << 9).isValid) // 仅 ⇧
        XCTAssertFalse(GlobalShortcut(keyCode: 49, modifiers: 1 << 10).isValid) // 仅 ⇪
    }

    /// 只用 ⌘（可加 ⇧）时仅限 Space 与 F 键：其余组合会覆盖各应用的同名快捷键（如 ⌘Q、⌘⇧Z）。
    func testCommandOnlyShortcutsAreLimitedToSpaceAndFunctionKeys() {
        XCTAssertEqual(GlobalShortcut(keyCode: 12, modifiers: 1 << 8).problem, .overridesAppShortcut) // ⌘Q
        XCTAssertEqual(GlobalShortcut(keyCode: 6, modifiers: 1 << 8 | 1 << 9).problem, .overridesAppShortcut) // ⌘⇧Z
        XCTAssertNil(GlobalShortcut(keyCode: 49, modifiers: 1 << 8).problem) // ⌘Space
        XCTAssertNil(GlobalShortcut(keyCode: 122, modifiers: 1 << 8).problem) // ⌘F1
        XCTAssertNil(GlobalShortcut(keyCode: 12, modifiers: 1 << 8 | 1 << 11).problem) // ⌥⌘Q
        XCTAssertNil(GlobalShortcut(keyCode: 12, modifiers: 1 << 8 | 1 << 12).problem) // ⌃⌘Q
        XCTAssertNil(GlobalShortcut.defaultTranslator.problem) // ⌥D
        XCTAssertEqual(GlobalShortcut(keyCode: 49, modifiers: 1 << 9).problem, .missingModifier) // 仅 ⇧
    }
}
