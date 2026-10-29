import SwiftUI

@MainActor
struct LauncherView: View {
    @ObservedObject var viewModel: LauncherViewModel
    @ObservedObject var animation: PanelAnimationCoordinator
    let iconProvider: any IconProviding
    let onOpen: (SearchResult) -> Void
    let onAction: (ResultMenuAction, SearchResult) -> Void
    let onDismiss: () -> Void
    /// 复制 Quick AI 回答中的代码块。
    let onCopy: (String) -> Void

    var body: some View {
        VStack(spacing: 0) {
            Group {
                // 提问之后输入框移到对话下方，顶部的输入行变为标题栏。
                if let session = viewModel.quickAISession {
                    quickAIHeader(modelName: session.modelName)
                } else {
                    searchBar
                }
            }
            .frame(height: topRowHeight)
            // Quick AI 模式下按住输入框以外的空白处（提问之后为整个标题栏）拖动面板；检索模式下面板不可拖动。
            .contentShape(Rectangle())
            .gesture(WindowDragGesture(), including: viewModel.isQuickAIModeActive ? .all : .subviews)

            // 窗口高度由动画协调器逐帧设置，内容只是填满每帧发布的空间，因此不会与窗口边缘错位。
            // 是否挂载只跟随输入是否展开：列表在第一帧几何更新之前就已创建，而不是在动画中途创建
            // （窗口长高之前它的高度被限制为 0）。清空输入时仍立即卸载，与原生聚焦搜索收回胶囊的表现一致。
            if viewModel.isExpanded {
                divider
                Group {
                    if let session = viewModel.quickAISession {
                        QuickAIAnswerView(
                            session: session,
                            returnAction: viewModel.quickAIReturnAction ?? QuickAISession.ReturnAction.none,
                            scrollRequest: viewModel.quickAIScrollRequest,
                            onCopyCode: onCopy
                        ) {
                            // 与顶部的输入框共用问题草稿；回车等按键同样由面板统一处理。
                            LauncherSearchInput(
                                query: $viewModel.query,
                                style: .followUp,
                                isQuickAIMode: true,
                                focusRequest: viewModel.focusRequest,
                                onSubmit: {}
                            )
                        }
                    } else {
                        results
                    }
                }
                // 展开动画开头的高度还容不下 Quick AI 的追问框与页脚时，内容贴顶排列、超出部分由面板裁掉，
                // 不会向上盖住顶部一行。
                .frame(height: max(0, animation.currentHeight - topRowHeight - 1), alignment: .top)
            }
        }
        .frame(width: LauncherLayout.width, height: animation.currentHeight)
        .overlay(alignment: .bottomTrailing) {
            if viewModel.isActionSheetVisible,
               let selectedResult = viewModel.selectedResult {
                // 只取一次，空判断与卡片输入共用：该计算属性每次访问都会重建数组。
                let actions = viewModel.currentAvailableActions
                if !actions.isEmpty {
                    ZStack(alignment: .bottomTrailing) {
                        Color.clear
                            .contentShape(Rectangle())
                            .onTapGesture {
                                viewModel.dismissActionSheet()
                            }

                        LauncherActionSheetView(
                            result: selectedResult,
                            actions: actions,
                            selectedIndex: viewModel.selectedActionIndex,
                            iconProvider: iconProvider,
                            onSelect: { action in
                                onAction(action, selectedResult)
                            }
                        )
                        .padding(.trailing, LauncherLayout.actionSheetTrailingInset)
                        .padding(.bottom, LauncherLayout.actionSheetBottomInset)
                        .transition(
                            .asymmetric(
                                insertion: .scale(scale: 0.94, anchor: .bottomTrailing)
                                    .combined(with: .opacity),
                                removal: .scale(scale: 0.94, anchor: .bottomTrailing)
                                    .combined(with: .opacity)
                            )
                        )
                    }
                    .frame(width: LauncherLayout.width, height: animation.currentHeight)
                }
            }
        }
        .animation(.spring(response: 0.22, dampingFraction: 0.82), value: viewModel.isActionSheetVisible)
        .onAppear { viewModel.requestFocus() }
        .onExitCommand {
            if viewModel.isActionSheetVisible {
                viewModel.dismissActionSheet()
            } else if viewModel.quickAISession != nil {
                onDismiss()
            } else if viewModel.isQuickAIModeActive {
                viewModel.toggleQuickAIMode()
            } else if !viewModel.query.isEmpty {
                viewModel.query = ""
            } else {
                onDismiss()
            }
        }
        .onMoveCommand { direction in
            if viewModel.isActionSheetVisible {
                switch direction {
                case .up: viewModel.moveActionSelection(by: -1)
                case .down: viewModel.moveActionSelection(by: 1)
                default: break
                }
            } else {
                switch direction {
                case .up: viewModel.moveSelection(by: -1)
                case .down: viewModel.moveSelection(by: 1)
                default: break
                }
            }
        }
    }

    private var searchBar: some View {
        HStack(spacing: 14) {
            LauncherSearchInput(
                query: $viewModel.query,
                isQuickAIMode: viewModel.isQuickAIModeActive,
                focusRequest: viewModel.focusRequest,
                onSubmit: {
                    guard let result = viewModel.selectedResult else { return }
                    onOpen(result)
                }
            )
            .frame(maxWidth: .infinity)
            .frame(height: 36)

            if viewModel.isQuickAIModeActive {
                // Quick AI 模式由输入框左侧的 ✨ 表明，右侧不再重复。
                EmptyView()
            } else if viewModel.isLoading {
                ProgressView()
                    .controlSize(.small)
            } else if let result = viewModel.selectedResult {
                if let symbolName = result.symbolName {
                    Image(systemName: symbolName)
                        .font(.system(size: 22))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                } else if let url = result.url {
                    Image(nsImage: iconProvider.icon(for: url))
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 28, height: 28)
                }
            }
        }
        .padding(.horizontal, 20)
    }

    /// 顶部一行的高度：提问之后的标题栏比检索行矮，省下的高度归回答区，面板总高度不变。
    private var topRowHeight: CGFloat {
        viewModel.quickAISession == nil ? LauncherLayout.searchHeight : LauncherLayout.quickAIHeaderHeight
    }

    /// Quick AI 提问之后的标题栏：左边的 `‹` 与 `Tab` 相同，返回检索并结束这段对话；中间是「Quick AI · 模型名」。
    private func quickAIHeader(modelName: String) -> some View {
        ZStack {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .foregroundStyle(Color.accentColor)
                Text(verbatim: "Quick AI")
                    .fontWeight(.semibold)
                    .layoutPriority(1)
                if !modelName.isEmpty {
                    Text(verbatim: "· \(modelName)")
                        .foregroundStyle(.secondary)
                        .truncationMode(.middle)
                }
            }
            .font(.system(size: 15))
            .lineLimit(1)
            .padding(.horizontal, 64)

            HStack {
                QuickAIBackButton {
                    viewModel.toggleQuickAIMode()
                }
                Spacer()
            }
        }
        .padding(.horizontal, 14)
    }

    private var divider: some View {
        Color.primary.opacity(0.08)
            .frame(height: 1)
            .padding(.horizontal, 12)
    }

    private var results: some View {
        Group {
            if viewModel.quickQueryResult == nil,
               viewModel.webURLResult == nil,
               viewModel.pathResult == nil,
               let errorMessage = viewModel.errorMessage,
               viewModel.apps.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 28))
                        .foregroundStyle(.secondary)
                    Text(errorMessage)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                    Button("重试") {
                        viewModel.loadApps()
                    }
                    .buttonStyle(.glassProminent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if viewModel.quickQueryResult == nil,
                      viewModel.webURLResult == nil,
                      viewModel.pathResult == nil,
                      viewModel.isLoading,
                      viewModel.apps.isEmpty {
                VStack(spacing: 10) {
                    ProgressView()
                    Text("正在加载应用…")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if viewModel.results.isEmpty {
                VStack(spacing: 0) {
                    if let launchError = viewModel.launchErrorMessage {
                        launchErrorBanner(launchError)
                    }

                    VStack(spacing: 8) {
                        // 应用无匹配但文件查询仍在进行时，先不判定"无结果"。
                        if viewModel.isSearchingFiles {
                            ProgressView()
                        } else {
                            Image(systemName: "magnifyingglass")
                                .font(.system(size: 28))
                                .foregroundStyle(.secondary)
                            Text("没有找到匹配的结果")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 0) {
                    if let launchError = viewModel.launchErrorMessage {
                        launchErrorBanner(launchError)
                    }

                    LauncherResultsList(
                        rows: viewModel.rows,
                        selectedRowIndex: viewModel.selectedRowIndex,
                        resetRequest: viewModel.listResetRequest,
                        iconProvider: iconProvider,
                        onOpen: onOpen
                    )
                    .padding(.vertical, LauncherLayout.listVerticalPadding)
                }
            }
        }
    }

    private func launchErrorBanner(_ message: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.red)
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
        }
        .padding(.horizontal, 14)
        .frame(maxHeight: .infinity)
        .background(Color.red.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .padding(.horizontal, 12)
        .padding(.top, 4)
        .frame(height: LauncherLayout.launchErrorBannerHeight)
    }
}

/// 标题栏左侧的返回按钮：悬停时显示圆形淡底。
private struct QuickAIBackButton: View {
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "chevron.left")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
                .background(Color.primary.opacity(isHovered ? 0.08 : 0), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help("返回搜索")
        .accessibilityLabel("返回搜索")
    }
}
