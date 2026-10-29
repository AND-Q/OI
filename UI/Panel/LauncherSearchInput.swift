import AppKit
import SwiftUI

/// 占位文字与搜索图标走 AppKit 原生的材质渲染；Quick AI 模式下搜索图标换成强调色的 ✨。
struct LauncherSearchInput: NSViewRepresentable {
    @Binding var query: String
    var style: LauncherSearchInputView.Style = .search
    let isQuickAIMode: Bool
    let focusRequest: Int
    let onSubmit: () -> Void

    func makeNSView(context: Context) -> LauncherSearchInputView {
        LauncherSearchInputView(style: style)
    }

    func updateNSView(_ nsView: LauncherSearchInputView, context: Context) {
        nsView.onQueryChange = { query = $0 }
        nsView.onSubmit = onSubmit
        nsView.update(query: query, isQuickAIMode: isQuickAIMode, focusRequest: focusRequest)
    }
}

final class LauncherSearchInputView: NSView, NSTextFieldDelegate {
    /// 面板顶部的检索框（Quick AI 的第一个问题也在这里输入），或 Quick AI 提问之后对话下方的追问框：
    /// 追问框字号较小、没有搜索图标。
    enum Style {
        case search
        case followUp
    }

    let textField = NSTextField()
    private let style: Style
    private let searchIcon = NSImageView()
    private var isShowingQuickAIIcon = false
    private var lastFocusRequest: Int?
    var onQueryChange: ((String) -> Void)?
    var onSubmit: (() -> Void)?

    init(style: Style = .search) {
        self.style = style
        super.init(frame: .zero)

        searchIcon.image = Self.iconImage(named: "magnifyingglass")
        searchIcon.contentTintColor = .placeholderTextColor
        searchIcon.imageScaling = .scaleProportionallyDown
        searchIcon.setAccessibilityElement(false)

        textField.isBordered = false
        textField.isBezeled = false
        textField.drawsBackground = false
        textField.focusRingType = .none
        textField.font = .systemFont(ofSize: style == .search ? 26 : 15, weight: .regular)
        textField.textColor = .labelColor
        textField.placeholderString = String(localized: "聚焦搜索")
        textField.cell?.usesSingleLineMode = true
        textField.cell?.isScrollable = true
        textField.cell?.sendsActionOnEndEditing = false
        textField.setAccessibilityLabel(String(localized: "聚焦搜索"))
        textField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textField.delegate = self
        textField.target = self
        textField.action = #selector(submit)

        switch style {
        case .search:
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
        case .followUp:
            textField.translatesAutoresizingMaskIntoConstraints = false
            addSubview(textField)
            NSLayoutConstraint.activate([
                textField.leadingAnchor.constraint(equalTo: leadingAnchor),
                textField.trailingAnchor.constraint(equalTo: trailingAnchor),
                textField.centerYAnchor.constraint(equalTo: centerYAnchor),
            ])
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(query: String, isQuickAIMode: Bool, focusRequest: Int) {
        let placeholder = switch style {
        case .search:
            isQuickAIMode ? String(localized: "向 AI 提问，按回车发送") : String(localized: "聚焦搜索")
        case .followUp:
            String(localized: "继续追问")
        }
        if textField.placeholderString != placeholder {
            textField.placeholderString = placeholder
            textField.setAccessibilityLabel(placeholder)
        }
        // 左侧图标表明此时输入的是检索词还是问题。
        if isShowingQuickAIIcon != isQuickAIMode {
            isShowingQuickAIIcon = isQuickAIMode
            searchIcon.image = Self.iconImage(named: isQuickAIMode ? "sparkles" : "magnifyingglass")
            searchIcon.contentTintColor = isQuickAIMode ? .controlAccentColor : .placeholderTextColor
        }

        // SwiftUI 在面板动画期间也会更新这个桥接视图。输入法仍在组字时，绝不替换未上屏的文字。
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

    private static func iconImage(named symbolName: String) -> NSImage? {
        NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 24, weight: .regular))
    }

    func controlTextDidChange(_ notification: Notification) {
        onQueryChange?(textField.stringValue)
    }

    @objc private func submit() {
        guard (textField.currentEditor() as? NSTextView)?.hasMarkedText() != true else { return }
        onSubmit?()
    }
}
