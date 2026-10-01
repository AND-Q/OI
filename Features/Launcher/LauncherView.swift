import SwiftUI

/// Layout metrics calibrated against the macOS 27 Spotlight reference images.
enum LauncherLayout {
    static let width: CGFloat = 640
    static let searchHeight: CGFloat = 57
    static let rowHeight: CGFloat = 56
    static let sectionHeaderHeight: CGFloat = 24
    static let listVerticalPadding: CGFloat = 8
    static let statusHeight: CGFloat = 205
    static let maximumVisibleRows = 7

    static let compactCornerRadius: CGFloat = searchHeight / 2
    static let expandedCornerRadius: CGFloat = 32
    /// Minimum panel expansion reserved for the floating action sheet.
    static let actionSheetMinHeight: CGFloat = 185
    /// Quick AI answer area (answer plus footer), fixed so streaming never resizes the window.
    static let quickAIHeight: CGFloat = 400
    static let quickAIFooterHeight: CGFloat = 32

    /// What the expanded area below the search field shows.
    enum ExpandedContent: Equatable {
        case results(rowCount: Int, sectionHeaderCount: Int = 0, minHeight: CGFloat = 0)
        case status
        case quickAI

        var height: CGFloat {
            switch self {
            case .results(let rowCount, let sectionHeaderCount, let minHeight):
                let contentHeight = CGFloat(max(rowCount, 0)) * LauncherLayout.rowHeight
                    + CGFloat(max(sectionHeaderCount, 0)) * LauncherLayout.sectionHeaderHeight
                let maximumHeight = CGFloat(LauncherLayout.maximumVisibleRows) * LauncherLayout.rowHeight
                let baseHeight = LauncherLayout.listVerticalPadding * 2 + min(contentHeight, maximumHeight)
                return max(baseHeight, minHeight)
            case .status:
                return LauncherLayout.statusHeight
            case .quickAI:
                return LauncherLayout.quickAIHeight
            }
        }
    }

    static func totalHeight(isExpanded: Bool, content: ExpandedContent?) -> CGFloat {
        guard isExpanded, let content else { return searchHeight }
        return searchHeight + 1 + content.height
    }
}

@MainActor
struct LauncherView: View {
    @ObservedObject var viewModel: LauncherViewModel
    @ObservedObject var animation: PanelAnimationCoordinator
    let iconProvider: any ApplicationIconProviding
    let onOpen: (SearchResult) -> Void
    let onAction: (ResultMenuAction, SearchResult) -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            searchBar
                .frame(height: LauncherLayout.searchHeight)

            // The coordinator steps the window height; the content simply fills
            // whatever space is published each frame, so it can never drift
            // from the window edge. Mounting follows only the expanded query
            // state: the list is created before the first geometry tick instead
            // of mid-animation (its height clamps to 0 until the window grows).
            // Clearing the query still unmounts it immediately, matching native
            // Spotlight's collapse back to the capsule.
            if viewModel.isExpanded {
                divider
                Group {
                    if let session = viewModel.quickAISession {
                        QuickAIAnswerView(session: session, scrollRequest: viewModel.quickAIScrollRequest)
                    } else {
                        results
                    }
                }
                .frame(height: max(0, animation.currentHeight - LauncherLayout.searchHeight - 1))
            }
        }
        .frame(width: LauncherLayout.width, height: animation.currentHeight)
        .overlay(alignment: .bottomTrailing) {
            if viewModel.isActionSheetVisible,
               let selectedResult = viewModel.selectedResult {
                // Extract once for both the emptiness check and the sheet input;
                // the computed property rebuilds the array on every access.
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
                        .padding(.trailing, 16)
                        .padding(.bottom, 12)
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
                Image(systemName: "sparkles")
                    .font(.system(size: 22))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
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

    private var divider: some View {
        Color.primary.opacity(0.08)
            .frame(height: 1)
            .padding(.horizontal, 12)
    }

    private var results: some View {
        Group {
            if viewModel.quickQueryResult == nil,
               viewModel.webURLResult == nil,
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
        .padding(.vertical, 6)
        .background(Color.red.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .padding(.horizontal, 12)
        .padding(.top, 4)
    }
}
