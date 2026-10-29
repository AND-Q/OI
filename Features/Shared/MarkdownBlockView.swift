import SwiftUI

/// 一个 Markdown 块（标题、段落、列表、引用、代码、表格、分隔线）的显示，
/// 用于 Quick AI 回答与检查更新时的更新日志。
struct MarkdownBlockView: View {
    let block: MarkdownBlock
    /// 复制代码块；提供时代码块顶部多一条带语言名与「复制」按钮的标签栏（Quick AI 回答），更新日志不提供。
    var onCopyCode: ((String) -> Void)? = nil

    var body: some View {
        switch block {
        case .heading(let level, let text):
            Text(MarkdownParser.inline(text))
                .font(.system(size: level == 1 ? 20 : level == 2 ? 17 : 15, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)
        case .paragraph(let text):
            Text(MarkdownParser.inline(text))
                .font(.system(size: 14))
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        case .listItem(let marker, let text, let indent):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(marker)
                    .foregroundStyle(.secondary)
                Text(MarkdownParser.inline(text))
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.system(size: 14))
            .padding(.leading, CGFloat(indent) * 16)
        case .quote(let text):
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color.secondary.opacity(0.4))
                    .frame(width: 3)
                Text(MarkdownParser.inline(text))
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .fixedSize(horizontal: false, vertical: true)
        case .code(let language, let code):
            CodeBlockView(language: language, code: code, onCopy: onCopyCode)
        case .table(let header, let rows):
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                GridRow {
                    ForEach(Array(header.enumerated()), id: \.offset) { _, cell in
                        tableCell(cell)
                            .fontWeight(.semibold)
                    }
                }
                Divider()
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                            tableCell(cell)
                        }
                    }
                }
            }
            .font(.system(size: 13))
            .padding(10)
            .background(Color.primary.opacity(0.04))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        case .rule:
            Color.primary.opacity(0.1)
                .frame(height: 1)
        }
    }

    private func tableCell(_ text: String) -> some View {
        Text(MarkdownParser.inline(text))
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// 代码块：横向滚动的等宽文字；能复制时顶部是一条标签栏，左边是语言名，右边是「复制」按钮，
/// 点按后短暂显示「已复制」。
private struct CodeBlockView: View {
    let language: String
    let code: String
    let onCopy: ((String) -> Void)?

    @State private var isCopied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let onCopy {
                HStack {
                    Text(language)
                    Spacer()
                    Button {
                        onCopy(code)
                        isCopied = true
                    } label: {
                        Group {
                            if isCopied {
                                Label("已复制", systemImage: "checkmark")
                            } else {
                                Label("复制", systemImage: "doc.on.doc")
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .frame(height: 24)
                .background(Color.primary.opacity(0.04))
            }
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(size: 12.5, design: .monospaced))
                    .fixedSize()
                    .padding(10)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .task(id: isCopied) {
            guard isCopied else { return }
            try? await Task.sleep(for: .seconds(1.5))
            isCopied = false
        }
    }
}
