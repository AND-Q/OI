import Carbon.HIToolbox
import Foundation

/// 全局快捷键的人类可读展示：修饰键符号 + 按键名。
/// 仅使用 Carbon 键码常量做查询，不使用 Carbon 界面 API。
enum ShortcutFormatter {
    /// 修饰键符号，按系统惯例 ⌃ ⌥ ⇧ ⌘ 排序。
    static func modifierSymbols(for modifiers: UInt32) -> [String] {
        var symbols: [String] = []
        if modifiers & UInt32(controlKey) != 0 { symbols.append("⌃") }
        if modifiers & UInt32(optionKey) != 0 { symbols.append("⌥") }
        if modifiers & UInt32(shiftKey) != 0 { symbols.append("⇧") }
        if modifiers & UInt32(cmdKey) != 0 { symbols.append("⌘") }
        return symbols
    }

    /// 按键名；字母与数字按 ANSI 布局展示，未收录的键码回退为「按键 N」。
    static func keyName(for keyCode: UInt32) -> String {
        if let name = keyNames[keyCode] {
            return name
        }
        return String(localized: "按键 \(Int(keyCode))")
    }

    static func displayName(for shortcut: GlobalShortcut) -> String {
        (modifierSymbols(for: shortcut.modifiers) + [keyName(for: shortcut.keyCode)])
            .joined(separator: " ")
    }

    /// 组合不能用作全局快捷键的原因，录制时的行内提示与设置面板的失败提示共用。
    static func description(of problem: GlobalShortcut.Problem) -> String {
        switch problem {
        case .missingModifier:
            String(localized: "快捷键需包含 ⌘、⌥ 或 ⌃ 修饰键")
        case .overridesAppShortcut:
            String(localized: "只用 ⌘ 会覆盖各应用的同名快捷键，请加上 ⌥ 或 ⌃")
        }
    }

    private static let keyNames: [UInt32: String] = {
        var names: [UInt32: String] = [:]
        let letters: [(Int, String)] = [
            (kVK_ANSI_A, "A"), (kVK_ANSI_B, "B"), (kVK_ANSI_C, "C"), (kVK_ANSI_D, "D"),
            (kVK_ANSI_E, "E"), (kVK_ANSI_F, "F"), (kVK_ANSI_G, "G"), (kVK_ANSI_H, "H"),
            (kVK_ANSI_I, "I"), (kVK_ANSI_J, "J"), (kVK_ANSI_K, "K"), (kVK_ANSI_L, "L"),
            (kVK_ANSI_M, "M"), (kVK_ANSI_N, "N"), (kVK_ANSI_O, "O"), (kVK_ANSI_P, "P"),
            (kVK_ANSI_Q, "Q"), (kVK_ANSI_R, "R"), (kVK_ANSI_S, "S"), (kVK_ANSI_T, "T"),
            (kVK_ANSI_U, "U"), (kVK_ANSI_V, "V"), (kVK_ANSI_W, "W"), (kVK_ANSI_X, "X"),
            (kVK_ANSI_Y, "Y"), (kVK_ANSI_Z, "Z"),
        ]
        let digits: [(Int, String)] = [
            (kVK_ANSI_0, "0"), (kVK_ANSI_1, "1"), (kVK_ANSI_2, "2"), (kVK_ANSI_3, "3"),
            (kVK_ANSI_4, "4"), (kVK_ANSI_5, "5"), (kVK_ANSI_6, "6"), (kVK_ANSI_7, "7"),
            (kVK_ANSI_8, "8"), (kVK_ANSI_9, "9"),
        ]
        let punctuation: [(Int, String)] = [
            (kVK_ANSI_Grave, "`"), (kVK_ANSI_Minus, "-"), (kVK_ANSI_Equal, "="),
            (kVK_ANSI_LeftBracket, "["), (kVK_ANSI_RightBracket, "]"),
            (kVK_ANSI_Backslash, "\\"), (kVK_ANSI_Semicolon, ";"), (kVK_ANSI_Quote, "'"),
            (kVK_ANSI_Comma, ","), (kVK_ANSI_Period, "."), (kVK_ANSI_Slash, "/"),
        ]
        let specialKeys: [(Int, String)] = [
            (kVK_Space, "Space"), (kVK_Return, "Return"), (kVK_Tab, "Tab"),
            (kVK_Escape, "Esc"), (kVK_Delete, "Delete"), (kVK_ForwardDelete, "⌦"),
            (kVK_Home, "Home"), (kVK_End, "End"), (kVK_PageUp, "PageUp"),
            (kVK_PageDown, "PageDown"), (kVK_LeftArrow, "←"), (kVK_RightArrow, "→"),
            (kVK_DownArrow, "↓"), (kVK_UpArrow, "↑"), (kVK_CapsLock, "⇪"),
        ]
        let functionKeys: [(Int, String)] = [
            (kVK_F1, "F1"), (kVK_F2, "F2"), (kVK_F3, "F3"), (kVK_F4, "F4"),
            (kVK_F5, "F5"), (kVK_F6, "F6"), (kVK_F7, "F7"), (kVK_F8, "F8"),
            (kVK_F9, "F9"), (kVK_F10, "F10"), (kVK_F11, "F11"), (kVK_F12, "F12"),
            (kVK_F13, "F13"), (kVK_F14, "F14"), (kVK_F15, "F15"), (kVK_F16, "F16"),
            (kVK_F17, "F17"), (kVK_F18, "F18"), (kVK_F19, "F19"), (kVK_F20, "F20"),
        ]
        let keypadKeys: [(Int, String)] = [
            (kVK_ANSI_Keypad0, "Num 0"), (kVK_ANSI_Keypad1, "Num 1"),
            (kVK_ANSI_Keypad2, "Num 2"), (kVK_ANSI_Keypad3, "Num 3"),
            (kVK_ANSI_Keypad4, "Num 4"), (kVK_ANSI_Keypad5, "Num 5"),
            (kVK_ANSI_Keypad6, "Num 6"), (kVK_ANSI_Keypad7, "Num 7"),
            (kVK_ANSI_Keypad8, "Num 8"), (kVK_ANSI_Keypad9, "Num 9"),
            (kVK_ANSI_KeypadDecimal, "Num ."), (kVK_ANSI_KeypadMultiply, "Num *"),
            (kVK_ANSI_KeypadPlus, "Num +"), (kVK_ANSI_KeypadMinus, "Num -"),
            (kVK_ANSI_KeypadDivide, "Num /"), (kVK_ANSI_KeypadEquals, "Num ="),
            (kVK_ANSI_KeypadEnter, "Num Enter"), (kVK_ANSI_KeypadClear, "Num Clear"),
        ]
        for group in [letters, digits, punctuation, specialKeys, functionKeys, keypadKeys] {
            for (keyCode, name) in group {
                names[UInt32(keyCode)] = name
            }
        }
        return names
    }()
}
