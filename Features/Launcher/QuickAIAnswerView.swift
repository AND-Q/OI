import SwiftUI

/// Quick AI 回答区：按轮次往下排列的提问与流式显示的 Markdown 回答，追问框以玻璃胶囊浮在对话底部，
/// 对话从它下面滚过。追问框里的输入控件由面板提供（`input`），与顶部的检索框是同一种原生输入框。
@MainActor
struct QuickAIAnswerView<Input: View>: View {
    let session: QuickAISession
    let returnAction: QuickAISession.ReturnAction
    let scrollRequest: QuickAIScrollRequest
    /// 复制代码块（代码块右上角的「复制」）。
    let onCopyCode: (String) -> Void
    let input: Input

    /// `↑` / `↓` 每次滚动的距离。
    private static var keyboardScrollStep: CGFloat { 60 }
    /// 回答区顶部边缘渐隐的高度。
    private static var edgeFadeHeight: CGFloat { 20 }

    @State private var position = ScrollPosition(edge: .top)
    @State private var metrics = ScrollMetrics()
    @State private var isPinnedToBottom = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    init(
        session: QuickAISession,
        returnAction: QuickAISession.ReturnAction,
        scrollRequest: QuickAIScrollRequest,
        onCopyCode: @escaping (String) -> Void,
        @ViewBuilder input: () -> Input
    ) {
        self.session = session
        self.returnAction = returnAction
        self.scrollRequest = scrollRequest
        self.onCopyCode = onCopyCode
        self.input = input()
    }

    var body: some View {
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
            // 底部留出的追问框高度（`contentInsets.bottom`）也可以滚动，滚到底时最后一行停在追问框上方。
            let maxOffset = max(
                geometry.contentSize.height + geometry.contentInsets.bottom - geometry.containerSize.height,
                0
            )
            return ScrollMetrics(
                offset: geometry.contentOffset.y,
                maxOffset: maxOffset,
                isAtBottom: geometry.contentOffset.y >= maxOffset - 8
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
        // 底部经过追问框的内容由系统的滚动边缘效果渐进模糊，顶部仍用自己的渐隐。
        .scrollEdgeEffectStyle(.soft, for: .bottom)
        .mask { topFadeMask }
        // 追问框浮在对话底部：对话从玻璃胶囊下面滚过，玻璃才有内容可以折射。
        .safeAreaBar(edge: .bottom, spacing: 0) {
            composer
                .frame(height: LauncherLayout.quickAIComposerHeight)
        }
        // 面板展开动画开头的高度还容不下追问框时保持追问框的高度，向下超出的部分由面板裁掉，不往上盖住标题栏。
        .frame(minHeight: LauncherLayout.quickAIComposerHeight)
    }

    /// 新的一轮从下方淡入；开启「减弱动态效果」时只淡入。
    private var turnTransition: AnyTransition {
        reduceMotion ? .opacity : .opacity.combined(with: .offset(y: 12))
    }

    /// 顶部边缘柔和渐隐：上方有翻过去的内容时淡出，内容不在标题栏下方被硬生生截断。
    private var topFadeMask: some View {
        let fadesTop = metrics.offset > 1
        return VStack(spacing: 0) {
            LinearGradient(colors: [.black.opacity(fadesTop ? 0 : 1), .black], startPoint: .top, endPoint: .bottom)
                .frame(height: Self.edgeFadeHeight)
            Color.black
        }
        .animation(.easeOut(duration: 0.15), value: fadesTop)
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
            let blocks = MarkdownParser.blocks(from: visibleAnswer)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                    MarkdownBlockView(block: block, onCopyCode: onCopyCode)
                        .padding(.top, index == 0 ? 0 : Self.spacing(between: blocks[index - 1], and: block))
                }
            }
            // 已经出字、仍在输出时，在最后一段下方保留缩小的圆点，表明回答还没结束。
            if turn.state == .streaming {
                ThinkingIndicator(dotSize: 4)
            }
            if case .failed(let message) = turn.state {
                errorLabel(message)
            }
        }
    }

    /// 回答中相邻两块的间距：同一列表的条目靠紧，标题与上文拉开、与下文靠近，其余为段落间距。
    private static func spacing(between previous: MarkdownBlock, and block: MarkdownBlock) -> CGFloat {
        switch (previous, block) {
        case (.listItem, .listItem): 4
        case (_, .heading): 16
        case (.heading, _): 6
        default: 10
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

    /// 对话底部的玻璃胶囊追问框：半径 18、左右与下方各留 14pt，与面板 32pt 的圆角同心。
    private var composer: some View {
        HStack(spacing: 10) {
            input
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            hint
        }
        .font(.system(size: 12))
        .padding(.leading, 16)
        .padding(.trailing, 10)
        .frame(height: 36)
        // 比周围亮一层并带柔和阴影，像浮在对话上的一块：纯白背景上也看得出胶囊，又不靠压暗显得发灰；
        // 底色只是半透明，经过的内容仍会透过它被折射。
        .background {
            Capsule()
                .fill(Color.white.opacity(colorScheme == .dark ? 0.08 : 0.6))
                .shadow(color: .black.opacity(colorScheme == .dark ? 0.3 : 0.08), radius: 10, y: 3)
        }
        .glassEffect(.regular, in: Capsule())
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .padding(.bottom, 14)
    }

    /// 追问框右端只放此刻最有用的一个提示：刚复制过时为「已复制」（写追问时让位给追问），输出期间为中断，
    /// 否则为回车的作用，与面板的 Enter 处理一致：输入框有文字时追问，失败或无内容时重试，否则复制并关闭。
    private var hint: some View {
        Group {
            if session.isAnswerCopied, returnAction != .followUp {
                Label("已复制", systemImage: "checkmark")
                    .foregroundStyle(.secondary)
            } else {
                switch returnAction {
                case .followUp:
                    shortcutHint("↩", "追问")
                case .copyAndClose:
                    shortcutHint("↩", "复制并关闭")
                case .retry:
                    shortcutHint("↩", "重试")
                case .none:
                    // 回车只在输出期间不响应，此时最需要知道的是怎样中断。
                    shortcutHint("esc", "中断并关闭")
                }
            }
        }
        .transition(.opacity)
        .animation(.easeOut(duration: 0.2), value: session.isAnswerCopied)
    }

    /// 键帽底色比胶囊的淡底深一些，叠在上面仍看得清。
    private func shortcutHint(_ key: String, _ title: LocalizedStringKey) -> some View {
        HStack(spacing: 4) {
            Text(key)
                .font(.system(size: 11, weight: .medium))
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(Color.primary.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 4))
            Text(title)
        }
        .foregroundStyle(.secondary)
    }
}

/// 等待回答时三个依次起伏的小圆点（已经出字、仍在输出时用缩小的一组）；开启「减弱动态效果」时只明暗变化、不跳动。
private struct ThinkingIndicator: View {
    /// 一次起伏的周期（秒）。
    private static let period: Double = 1.2

    var dotSize: CGFloat = 6

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 4) {
                ForEach(0..<3, id: \.self) { index in
                    // 每个圆点比前一个晚六分之一周期，只在正弦的上半周起伏，其余时间停在原处。
                    let lift = max(0, sin(time * 2 * Double.pi / Self.period - Double(index) * Double.pi / 3))
                    Circle()
                        .frame(width: dotSize, height: dotSize)
                        .opacity(0.35 + 0.65 * lift)
                        .offset(y: reduceMotion ? 0 : -CGFloat(lift) * dotSize / 2)
                }
            }
        }
        .foregroundStyle(.secondary)
        .frame(height: dotSize * 3)
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
