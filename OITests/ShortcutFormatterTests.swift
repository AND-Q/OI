import Foundation
import XCTest

@testable import OI

final class ShortcutFormatterTests: XCTestCase {
    func testModifierSymbolsFollowSystemOrder() {
        // ⌃ ⌥ ⇧ ⌘ = 1 << 12 | 1 << 11 | 1 << 9 | 1 << 8。
        let all = GlobalShortcut(keyCode: 49, modifiers: (1 << 8) | (1 << 9) | (1 << 11) | (1 << 12))
        XCTAssertEqual(ShortcutFormatter.modifierSymbols(for: all.modifiers), ["⌃", "⌥", "⇧", "⌘"])
        XCTAssertEqual(ShortcutFormatter.modifierSymbols(for: 0), [])
    }

    func testKeyNamesForCommonKeys() {
        XCTAssertEqual(ShortcutFormatter.keyName(for: 49), "Space")
        XCTAssertEqual(ShortcutFormatter.keyName(for: 36), "Return")
        XCTAssertEqual(ShortcutFormatter.keyName(for: 53), "Esc")
        XCTAssertEqual(ShortcutFormatter.keyName(for: 0), "A")
        XCTAssertEqual(ShortcutFormatter.keyName(for: 18), "1")
        XCTAssertEqual(ShortcutFormatter.keyName(for: 122), "F1")
        XCTAssertEqual(ShortcutFormatter.keyName(for: 123), "←")
        // 小键盘：82 = kVK_ANSI_Keypad0，76 = kVK_ANSI_KeypadEnter，69 = kVK_ANSI_KeypadPlus。
        XCTAssertEqual(ShortcutFormatter.keyName(for: 82), "Num 0")
        XCTAssertEqual(ShortcutFormatter.keyName(for: 76), "Num Enter")
        XCTAssertEqual(ShortcutFormatter.keyName(for: 69), "Num +")
    }

    func testUnknownKeyCodeFallsBackToPlaceholder() {
        XCTAssertEqual(ShortcutFormatter.keyName(for: UInt32.max), "按键 4294967295")
    }

    func testShortcutErrorCodesAreNotGrouped() {
        XCTAssertEqual(GlobalShortcutError.registrationFailed(-9870).errorDescription, "无法注册全局快捷键（-9870）")
        XCTAssertEqual(
            GlobalShortcutError.eventHandlerInstallationFailed(-9860).errorDescription,
            "无法安装全局快捷键事件处理器（-9860）"
        )
    }

    func testDisplayNameJoinsModifiersAndKey() {
        let shortcut = GlobalShortcut(keyCode: 49, modifiers: 1 << 11)
        XCTAssertEqual(ShortcutFormatter.displayName(for: shortcut), "⌥ Space")
    }
}
