import AppKit
import SwiftUI

/// Keep placeholder text and its symbol in AppKit's native material rendering path.
struct LauncherSearchInput: NSViewRepresentable {
    @Binding var query: String
    let isQuickAIMode: Bool
    let focusRequest: Int
    let onSubmit: () -> Void

    func makeNSView(context: Context) -> LauncherSearchInputView {
        LauncherSearchInputView()
    }

    func updateNSView(_ nsView: LauncherSearchInputView, context: Context) {
        nsView.onQueryChange = { query = $0 }
        nsView.onSubmit = onSubmit
        nsView.update(query: query, isQuickAIMode: isQuickAIMode, focusRequest: focusRequest)
    }
}

final class LauncherSearchInputView: NSView, NSTextFieldDelegate {
    let textField = NSTextField()
    private let searchIcon = NSImageView()
    private var lastFocusRequest: Int?
    var onQueryChange: ((String) -> Void)?
    var onSubmit: (() -> Void)?

    init() {
        super.init(frame: .zero)

        searchIcon.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 24, weight: .regular))
        searchIcon.contentTintColor = .placeholderTextColor
        searchIcon.imageScaling = .scaleProportionallyDown
        searchIcon.setAccessibilityElement(false)

        textField.isBordered = false
        textField.isBezeled = false
        textField.drawsBackground = false
        textField.focusRingType = .none
        textField.font = .systemFont(ofSize: 26, weight: .regular)
        textField.textColor = .labelColor
        textField.placeholderString = "聚焦搜索"
        textField.cell?.usesSingleLineMode = true
        textField.cell?.isScrollable = true
        textField.cell?.sendsActionOnEndEditing = false
        textField.setAccessibilityLabel("聚焦搜索")
        textField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textField.delegate = self
        textField.target = self
        textField.action = #selector(submit)

        for view in [searchIcon, textField] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            searchIcon.leadingAnchor.constraint(equalTo: leadingAnchor),
            searchIcon.centerYAnchor.constraint(equalTo: centerYAnchor),
            searchIcon.widthAnchor.constraint(equalToConstant: 28),
            searchIcon.heightAnchor.constraint(equalToConstant: 28),
            textField.leadingAnchor.constraint(equalTo: searchIcon.trailingAnchor, constant: 14),
            textField.trailingAnchor.constraint(equalTo: trailingAnchor),
            textField.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(query: String, isQuickAIMode: Bool, focusRequest: Int) {
        let placeholder = isQuickAIMode ? "向 AI 提问，按回车发送" : "聚焦搜索"
        if textField.placeholderString != placeholder {
            textField.placeholderString = placeholder
            textField.setAccessibilityLabel(placeholder)
        }

        // SwiftUI also updates this bridge during panel animations. Never replace
        // marked text while the input method is still composing a candidate.
        let editor = textField.currentEditor() as? NSTextView
        if textField.stringValue != query, editor?.hasMarkedText() != true {
            textField.stringValue = query
        }

        guard lastFocusRequest != focusRequest else { return }
        lastFocusRequest = focusRequest
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window, window.isKeyWindow,
                  self.textField.currentEditor() == nil else { return }
            window.makeFirstResponder(self.textField)
        }
    }

    func controlTextDidChange(_ notification: Notification) {
        onQueryChange?(textField.stringValue)
    }

    @objc private func submit() {
        guard (textField.currentEditor() as? NSTextView)?.hasMarkedText() != true else { return }
        onSubmit?()
    }
}
