import SwiftUI

/// Quick AI answer area: streamed Markdown plus a footer with state and shortcuts.
@MainActor
struct QuickAIAnswerView: View {
    let session: QuickAISession

    private static let bottomAnchor = "quick-ai-bottom"

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        content
                        Color.clear
                            .frame(height: 1)
                            .id(Self.bottomAnchor)
                    }
                    .padding(.horizontal, 22)
                    .padding(.vertical, 14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                // 流式输出期间跟随最新内容；结束后不再抢夺用户的滚动位置。
                .onChange(of: session.answer) {
                    guard session.isStreaming else { return }
                    proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
                }
            }

            footer
                .frame(height: LauncherLayout.quickAIFooterHeight)
        }
    }

    @ViewBuilder
    private var content: some View {
        if session.answer.isEmpty {
            switch session.state {
            case .streaming:
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("正在思考…")
                        .foregroundStyle(.secondary)
                }
            case .finished:
                Text("没有收到回答")
                    .foregroundStyle(.secondary)
            case .failed(let message):
                errorLabel(message)
            }
        } else {
            ForEach(Array(QuickAIMarkdown.blocks(from: session.answer).enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
            if case .failed(let message) = session.state {
                errorLabel(message)
            }
        }
    }

    @ViewBuilder
    private func blockView(_ block: QuickAIMarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            Text(QuickAIMarkdown.inline(text))
                .font(.system(size: level == 1 ? 20 : level == 2 ? 17 : 15, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)
        case .paragraph(let text):
            Text(QuickAIMarkdown.inline(text))
                .font(.system(size: 14))
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        case .listItem(let marker, let text, let indent):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(marker)
                    .foregroundStyle(.secondary)
                Text(QuickAIMarkdown.inline(text))
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
                Text(QuickAIMarkdown.inline(text))
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .fixedSize(horizontal: false, vertical: true)
        case .code(_, let code):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(size: 12.5, design: .monospaced))
                    .fixedSize()
                    .padding(10)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        case .rule:
            Color.primary.opacity(0.1)
                .frame(height: 1)
        }
    }

    private func errorLabel(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.system(size: 13))
            .foregroundStyle(.red)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var footer: some View {
        HStack(spacing: 14) {
            Label("Quick AI", systemImage: "sparkles")
                .foregroundStyle(.secondary)
            if session.isAnswerCopied {
                Text("已复制到剪贴板")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            shortcutHint("↩", "复制并关闭")
            shortcutHint("⌘C", "复制")
            shortcutHint("⇥", "返回搜索")
            shortcutHint("esc", session.isStreaming ? "中断并关闭" : "关闭")
        }
        .font(.system(size: 12))
        .padding(.horizontal, 18)
        .background(Color.primary.opacity(0.03))
    }

    private func shortcutHint(_ key: String, _ title: String) -> some View {
        HStack(spacing: 4) {
            Text(key)
                .font(.system(size: 11, weight: .medium))
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(Color.primary.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 4))
            Text(title)
        }
        .foregroundStyle(.secondary)
    }
}
