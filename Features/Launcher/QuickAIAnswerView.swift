import SwiftUI

/// Quick AI answer area: streamed Markdown plus a footer with state and shortcuts.
@MainActor
struct QuickAIAnswerView: View {
    let session: QuickAISession
    let scrollRequest: QuickAIScrollRequest

    /// `↑` / `↓` 每次滚动的距离。
    private static let keyboardScrollStep: CGFloat = 60

    @State private var position = ScrollPosition(edge: .top)
    @State private var metrics = ScrollMetrics()
    @State private var isPinnedToBottom = true

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    content
                }
                .textSelection(.enabled)
                .padding(.horizontal, 22)
                .padding(.vertical, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollPosition($position)
            .onScrollGeometryChange(for: ScrollMetrics.self) { geometry in
                ScrollMetrics(
                    offset: geometry.contentOffset.y,
                    maxOffset: max(geometry.contentSize.height - geometry.containerSize.height, 0),
                    isAtBottom: geometry.visibleRect.maxY >= geometry.contentSize.height - 8
                )
            } action: { old, new in
                metrics = new
                // 只有滚动位置变化（手动、键盘或自动跟随）才更新贴底状态；内容增长不算离开底部。
                if new.offset != old.offset {
                    isPinnedToBottom = new.isAtBottom
                }
            }
            // 流式输出期间仅在停留底部时跟随最新内容；往上翻看时不再被拉回。
            .onChange(of: session.answer) {
                guard session.isStreaming, isPinnedToBottom else { return }
                position.scrollTo(edge: .bottom)
            }
            .onChange(of: scrollRequest) { _, request in
                let target = min(
                    max(metrics.offset + CGFloat(request.direction) * Self.keyboardScrollStep, 0),
                    metrics.maxOffset
                )
                withAnimation(.easeOut(duration: 0.15)) {
                    position.scrollTo(y: target)
                }
            }

            footer
                .frame(height: LauncherLayout.quickAIFooterHeight)
        }
    }

    @ViewBuilder
    private var content: some View {
        let visibleAnswer = QuickAIMarkdown.removingThinking(from: session.answer)
        if visibleAnswer.isEmpty {
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
            ForEach(Array(QuickAIMarkdown.blocks(from: visibleAnswer).enumerated()), id: \.offset) { _, block in
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
        Text(QuickAIMarkdown.inline(text))
            .fixedSize(horizontal: false, vertical: true)
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
            // 输出完成前 Enter 不复制半截回答，提示也随之隐藏。
            if !session.isStreaming {
                shortcutHint("↩", "复制并关闭")
            }
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

/// 回答区滚动状态：当前偏移、可滚动的最大偏移与是否停在底部。
private struct ScrollMetrics: Equatable {
    var offset: CGFloat = 0
    var maxOffset: CGFloat = 0
    var isAtBottom = true
}
