import AppKit
import Foundation
import XCTest

@testable import OI

@MainActor
final class LauncherSearchInputTests: XCTestCase {
    func testNativeSearchInputSynchronizesEditingAndProgrammaticClear() {
        let input = LauncherSearchInputView()
        var changes: [String] = []
        input.onQueryChange = { changes.append($0) }
        input.update(query: "we", isQuickAIMode: false, focusRequest: 0)
        XCTAssertEqual(input.textField.stringValue, "we")
        XCTAssertTrue(changes.isEmpty)

        input.textField.stringValue = "微信"
        input.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: input.textField))
        XCTAssertEqual(changes, ["微信"])

        input.update(query: "", isQuickAIMode: false, focusRequest: 1)
        XCTAssertEqual(input.textField.stringValue, "")
        XCTAssertEqual(changes, ["微信"])
    }

    func testNativeSearchInputSubmitsThroughItsAction() throws {
        let input = LauncherSearchInputView()
        var submissions = 0
        input.onSubmit = { submissions += 1 }
        let action = try XCTUnwrap(input.textField.action)
        XCTAssertTrue(input.textField.sendAction(action, to: input.textField.target))
        XCTAssertEqual(submissions, 1)
        XCTAssertFalse(try XCTUnwrap(input.textField.cell).sendsActionOnEndEditing)
    }

    func testNativeSearchInputPreservesMarkedTextDuringUpdates() throws {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 58),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        let input = LauncherSearchInputView()
        panel.contentView = input
        panel.contentView?.layoutSubtreeIfNeeded()
        XCTAssertTrue(panel.makeFirstResponder(input.textField))
        let editor = try XCTUnwrap(input.textField.currentEditor() as? NSTextView)
        defer { panel.makeFirstResponder(nil) }
        editor.setMarkedText("wei", selectedRange: NSRange(location: 3, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(editor.hasMarkedText())

        input.update(query: "", isQuickAIMode: false, focusRequest: 0)
        XCTAssertTrue(editor.hasMarkedText())
        XCTAssertEqual(editor.string, "wei")

        var submissions = 0
        input.onSubmit = { submissions += 1 }
        let action = try XCTUnwrap(input.textField.action)
        input.textField.sendAction(action, to: input.textField.target)
        XCTAssertEqual(submissions, 0)
    }

    func testNativeSearchInputClearsActiveEditorWhenNotComposing() throws {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 58),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        let input = LauncherSearchInputView()
        panel.contentView = input
        panel.contentView?.layoutSubtreeIfNeeded()
        XCTAssertTrue(panel.makeFirstResponder(input.textField))
        let editor = try XCTUnwrap(input.textField.currentEditor() as? NSTextView)
        defer { panel.makeFirstResponder(nil) }
        editor.string = "safari"
        input.textField.stringValue = "safari"

        input.update(query: "", isQuickAIMode: false, focusRequest: 0)
        XCTAssertEqual(input.textField.stringValue, "")
        XCTAssertEqual(editor.string, "")
    }
}
