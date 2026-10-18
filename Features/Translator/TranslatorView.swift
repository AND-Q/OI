import SwiftUI

/// 划词翻译气泡的版式参数。
enum TranslatorLayout {
    static let width: CGFloat = 380
    static let cornerRadius: CGFloat = 18
    /// 译文区的最大高度，超出后在区域内滚动。
    static let maximumTranslationHeight: CGFloat = 240
    /// 气泡可能达到的最大高度：据此决定弹在原文上方还是下方，避免译文增长途中翻转位置。
    static let maximumHeight: CGFloat = 420
    static let footerHeight: CGFloat = 30
}

/// 划词翻译气泡：语言方向与目标语言切换、原文（点按可修改）、流式译文与快捷键提示。
@MainActor
struct TranslatorView: View {
    @ObservedObject var viewModel: TranslatorViewModel
    /// 内容自然高度变化时通知面板同步窗口高度。
    let onHeightChange: (CGFloat) -> Void

    var body: some View {
        Group {
            if let session = viewModel.session {
                TranslatorSessionView(session: session, notice: viewModel.notice, viewModel: viewModel)
                    .id(session.id)
            } else if let notice = viewModel.notice {
                TranslatorNoticeView(notice: notice, viewModel: viewModel)
            }
        }
        .frame(width: TranslatorLayout.width)
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.height
        } action: { height in
            onHeightChange(height)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

@MainActor
private struct TranslatorSessionView: View {
    let session: TranslatorSession
    let notice: TranslatorNotice?
    let viewModel: TranslatorViewModel

    @State private var isEditingSource = false
    @FocusState private var isSourceFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 16)
                .padding(.top, 12)
            // 截图翻译识别期间还没有原文。
            if session.state != .recognizing {
                source
                    .padding(.horizontal, 16)
                    .padding(.top, 6)
                    .padding(.bottom, 10)
                Color.primary.opacity(0.08)
                    .frame(height: 1)
                    .padding(.horizontal, 12)
            }
            TranslationArea(session: session)
            if notice == .clipboardUsedWithoutAccessibility {
                accessibilityHint
            }
            footer
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text(session.sourceLanguageName ?? "自动识别")
            Image(systemName: "arrow.right")
                .font(.system(size: 9, weight: .semibold))
            Menu {
                ForEach(TranslationLanguage.allCases) { language in
                    Button {
                        viewModel.selectTargetLanguage(language)
                    } label: {
                        if language == session.targetLanguage {
                            Label(language.displayName, systemImage: "checkmark")
                        } else {
                            Text(language.displayName)
                        }
                    }
                }
            } label: {
                Text(session.targetLanguage.displayName)
                    .foregroundStyle(.primary)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.visible)
            .fixedSize()
            .help("切换本次翻译的目标语言")
            Spacer(minLength: 8)
            switch session.source {
            case .clipboard:
                Label("剪贴板", systemImage: "doc.on.clipboard")
            case .screen:
                Label("截图", systemImage: "text.viewfinder")
            case .selection, .word:
                EmptyView()
            }
        }
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
    }

    /// 原文默认只读展示，点按后才变为输入框：气泡弹出时不抢占焦点，⌘C 默认复制译文。
    @ViewBuilder
    private var source: some View {
        if isEditingSource {
            TextField("输入要翻译的文字", text: sourceBinding, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .lineLimit(1...6)
                .focused($isSourceFocused)
                .onAppear { isSourceFocused = true }
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(session.sourceText)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "pencil")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
            .onTapGesture { isEditingSource = true }
            .help("点按修改原文，按回车重新翻译")
        }
    }

    private var sourceBinding: Binding<String> {
        Binding(
            get: { viewModel.session?.sourceText ?? "" },
            set: { viewModel.updateSourceText($0) }
        )
    }

    private var accessibilityHint: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "exclamationmark.circle")
            Text("未开启辅助功能权限，读不到选中的文字，已翻译剪贴板内容。")
                .fixedSize(horizontal: false, vertical: true)
            Button("去开启") {
                viewModel.requestAccessibilityAccess()
            }
            .buttonStyle(.link)
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if session.isCopied {
                Text("已复制到剪贴板")
            }
            Spacer(minLength: 0)
            // 与面板的回车处理一致：输出期间不提示，待翻译、失败与没有译文时分别提示。
            switch session.returnAction {
            case .translate:
                TranslatorShortcutHint(key: "↩", title: "翻译")
            case .copyAndClose:
                TranslatorShortcutHint(key: "↩", title: "复制并关闭")
            case .retry:
                TranslatorShortcutHint(key: "↩", title: "重试")
            case .none:
                EmptyView()
            }
            if !session.visibleTranslation.isEmpty {
                TranslatorShortcutHint(key: "⌘C", title: "复制")
            }
            TranslatorShortcutHint(key: "esc", title: "关闭")
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .frame(height: TranslatorLayout.footerHeight)
        .background(Color.primary.opacity(0.03))
    }
}

/// 译文区：随内容增高，超过上限后在区域内滚动；输出期间停在底部时自动跟随最新内容。
@MainActor
private struct TranslationArea: View {
    let session: TranslatorSession

    @State private var contentHeight: CGFloat = 0
    @State private var position = ScrollPosition(edge: .top)
    @State private var isPinnedToBottom = true

    var body: some View {
        ScrollView {
            content
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.size.height
                } action: { height in
                    contentHeight = height
                }
        }
        .scrollPosition($position)
        .scrollBounceBehavior(.basedOnSize)
        .onScrollGeometryChange(for: ScrollState.self) { geometry in
            ScrollState(
                offset: geometry.contentOffset.y,
                isAtBottom: geometry.visibleRect.maxY >= geometry.contentSize.height - 8
            )
        } action: { old, new in
            // 只有滚动位置变化才更新贴底状态；内容增长不算离开底部。
            if new.offset != old.offset {
                isPinnedToBottom = new.isAtBottom
            }
        }
        .onChange(of: session.translation) {
            guard session.isStreaming, isPinnedToBottom else { return }
            position.scrollTo(edge: .bottom)
        }
        .frame(height: min(contentHeight, TranslatorLayout.maximumTranslationHeight))
    }

    @ViewBuilder
    private var content: some View {
        let translation = session.visibleTranslation
        VStack(alignment: .leading, spacing: 8) {
            if !translation.isEmpty {
                Text(translation)
                    .font(.system(size: 15))
                    .lineSpacing(3)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if case .failed(let message) = session.state {
                    errorLabel(message)
                }
            } else {
                switch session.state {
                case .recognizing:
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("正在识别文字…")
                            .foregroundStyle(.secondary)
                    }
                case .draft:
                    Text("原文已修改，按回车重新翻译")
                        .foregroundStyle(.secondary)
                case .streaming:
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("正在翻译…")
                            .foregroundStyle(.secondary)
                    }
                case .finished:
                    Text("没有收到译文")
                        .foregroundStyle(.secondary)
                case .failed(let message):
                    errorLabel(message)
                }
            }
        }
        .font(.system(size: 13))
    }

    private func errorLabel(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.system(size: 13))
            .foregroundStyle(.red)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// 没有可翻译的内容时只展示提示。
@MainActor
private struct TranslatorNoticeView: View {
    let notice: TranslatorNotice
    let viewModel: TranslatorViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                Label(message, systemImage: "text.badge.xmark")
                    .font(.system(size: 13))
                    .fixedSize(horizontal: false, vertical: true)
                switch notice {
                case .accessibilityRequired:
                    Button("开启辅助功能权限…") {
                        viewModel.requestAccessibilityAccess()
                    }
                    .controlSize(.small)
                case .screenRecordingRequired:
                    Button("开启屏幕录制权限…") {
                        viewModel.requestScreenCaptureAccess()
                    }
                    .controlSize(.small)
                case .clipboardUsedWithoutAccessibility, .nothingToTranslate, .noTextInSelection, .screenCaptureFailed:
                    EmptyView()
                }
            }
            .padding(16)
            HStack {
                Spacer()
                TranslatorShortcutHint(key: "esc", title: "关闭")
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14)
            .frame(height: TranslatorLayout.footerHeight)
            .background(Color.primary.opacity(0.03))
        }
    }

    private var message: String {
        switch notice {
        case .nothingToTranslate:
            "没有选中的文字，剪贴板中也没有可翻译的内容。"
        case .accessibilityRequired, .clipboardUsedWithoutAccessibility:
            "需要辅助功能权限才能读取选中的文字；也可以先复制文字，再按快捷键翻译剪贴板内容。"
        case .screenRecordingRequired:
            "截图翻译需要屏幕录制权限，用于截取框选的区域并在本机识别其中的文字。开启后请按系统提示重新打开 OI。"
        case .noTextInSelection:
            "选区中没有识别到文字，请重新框选。"
        case .screenCaptureFailed:
            "截图失败，请重新框选。如果刚开启屏幕录制权限，需要重新打开 OI 才能截图。"
        }
    }
}

private struct TranslatorShortcutHint: View {
    let key: String
    let title: String

    var body: some View {
        HStack(spacing: 4) {
            Text(key)
                .font(.system(size: 10.5, weight: .medium))
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(Color.primary.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 4))
            Text(title)
        }
    }
}

private struct ScrollState: Equatable {
    var offset: CGFloat
    var isAtBottom: Bool
}
