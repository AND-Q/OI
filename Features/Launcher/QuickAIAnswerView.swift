import SwiftUI

/// Quick AI 回答区：流式显示的 Markdown 回答，以及显示状态与快捷键的页脚。
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
        let visibleAnswer = MarkdownParser.removingThinking(from: session.answer)
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
            ForEach(Array(MarkdownParser.blocks(from: visibleAnswer).enumerated()), id: \.offset) { _, block in
                MarkdownBlockView(block: block)
            }
            if case .failed(let message) = session.state {
                errorLabel(message)
            }
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
            // 与面板的 Enter 处理一致：输出期间不提示，失败或无内容时提示重试。
            switch session.returnAction {
            case .copyAndClose:
                shortcutHint("↩", "复制并关闭")
            case .retry:
                shortcutHint("↩", "重试")
            case .none:
                EmptyView()
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
