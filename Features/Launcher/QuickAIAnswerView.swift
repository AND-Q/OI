import SwiftUI

/// Quick AI 回答区：按轮次往下排列的提问与流式显示的 Markdown 回答，以及显示状态与快捷键的页脚。
@MainActor
struct QuickAIAnswerView: View {
    let session: QuickAISession
    let returnAction: QuickAISession.ReturnAction
    let scrollRequest: QuickAIScrollRequest

    /// `↑` / `↓` 每次滚动的距离。
    private static let keyboardScrollStep: CGFloat = 60
    /// 回答区上下边缘渐隐的高度。
    private static let edgeFadeHeight: CGFloat = 20

    @State private var position = ScrollPosition(edge: .top)
    @State private var metrics = ScrollMetrics()
    @State private var isPinnedToBottom = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    ForEach(Array(session.turns.enumerated()), id: \.offset) { _, turn in
                        VStack(alignment: .leading, spacing: 10) {
                            questionBubble(turn.question)
                            answer(of: turn)
                        }
                        .transition(turnTransition)
                    }
                }
                // 只有追问新增一轮时带动画；流式增量与重试不改变轮数，照常立即上屏。
                .animation(.easeOut(duration: 0.25), value: session.turns.count)
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
            .onChange(of: session.lastTurn.answer) {
                guard session.isStreaming, isPinnedToBottom else { return }
                position.scrollTo(edge: .bottom)
            }
            // 发送新的问题时平滑滚到底部，此后照常跟随这一轮的输出。
            .onChange(of: session.turns.count) {
                isPinnedToBottom = true
                withAnimation(.easeOut(duration: 0.25)) {
                    position.scrollTo(edge: .bottom)
                }
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
            .mask { edgeFadeMask }

            // 按住页脚拖动面板，方便对照屏幕内容看回答；回答区留给选中文字。
            footer
                .frame(height: LauncherLayout.quickAIFooterHeight)
                .contentShape(Rectangle())
                .gesture(WindowDragGesture())
        }
    }

    /// 新的一轮从下方淡入；开启「减弱动态效果」时只淡入。
    private var turnTransition: AnyTransition {
        reduceMotion ? .opacity : .opacity.combined(with: .offset(y: 12))
    }

    /// 上下边缘柔和渐隐，内容不在面板边缘被硬生生截断：上方有翻过去的内容时淡出顶部，往上翻看、下方还有内容时
    /// 淡出底部；停在底部跟随输出时底部不淡出，避免每批增量到达时最新一行忽明忽暗。
    private var edgeFadeMask: some View {
        let fadesTop = metrics.offset > 1
        let fadesBottom = !isPinnedToBottom && metrics.offset < metrics.maxOffset - 1
        return VStack(spacing: 0) {
            LinearGradient(colors: [.black.opacity(fadesTop ? 0 : 1), .black], startPoint: .top, endPoint: .bottom)
                .frame(height: Self.edgeFadeHeight)
            Color.black
            LinearGradient(colors: [.black, .black.opacity(fadesBottom ? 0 : 1)], startPoint: .top, endPoint: .bottom)
                .frame(height: Self.edgeFadeHeight)
        }
        .animation(.easeOut(duration: 0.15), value: fadesTop)
        .animation(.easeOut(duration: 0.15), value: fadesBottom)
    }

    /// 提问显示为靠右的强调色气泡，与左侧的回答区分开；过长时换行，左侧至少留出一段空白。
    private func questionBubble(_ question: String) -> some View {
        HStack(spacing: 0) {
            Spacer(minLength: 80)
            Text(question)
                .font(.system(size: 14))
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(
                    Color.accentColor.opacity(0.18),
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                )
        }
    }

    @ViewBuilder
    private func answer(of turn: QuickAISession.Turn) -> some View {
        let visibleAnswer = turn.visibleAnswer
        if visibleAnswer.isEmpty {
            switch turn.state {
            case .streaming:
                ThinkingIndicator()
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
            if case .failed(let message) = turn.state {
                errorLabel(message)
            }
        }
    }

    /// 失败原因显示为淡红底的圆角卡片，与检索的失败横幅一致；文字用正文颜色，服务返回的长原因也不刺眼。
    private func errorLabel(_ message: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.red)
            Text(message)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 13))
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
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
            // 与面板的 Enter 处理一致：输出期间不提示，输入框有文字时提示追问，失败或无内容时提示重试。
            switch returnAction {
            case .followUp:
                shortcutHint("↩", "追问")
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

    private func shortcutHint(_ key: String, _ title: LocalizedStringKey) -> some View {
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

/// 等待回答时三个依次起伏的小圆点；开启「减弱动态效果」时只明暗变化、不跳动。
private struct ThinkingIndicator: View {
    /// 一次起伏的周期（秒）。
    private static let period: Double = 1.2

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 4) {
                ForEach(0..<3, id: \.self) { index in
                    // 每个圆点比前一个晚六分之一周期，只在正弦的上半周起伏，其余时间停在原处。
                    let lift = max(0, sin(time * 2 * Double.pi / Self.period - Double(index) * Double.pi / 3))
                    Circle()
                        .frame(width: 6, height: 6)
                        .opacity(0.35 + 0.65 * lift)
                        .offset(y: reduceMotion ? 0 : CGFloat(-3 * lift))
                }
            }
        }
        .foregroundStyle(.secondary)
        .frame(height: 18)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("正在思考…")
    }
}

/// 回答区滚动状态：当前偏移、可滚动的最大偏移与是否停在底部。
private struct ScrollMetrics: Equatable {
    var offset: CGFloat = 0
    var maxOffset: CGFloat = 0
    var isAtBottom = true
}
