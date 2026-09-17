import Combine
import SwiftUI

/// Pixel-matched layout metrics for the Spotlight-style launcher.
/// Values are derived from native Spotlight screenshots (see git history).
enum LauncherLayout {
    static let width: CGFloat = 640
    static let searchHeight: CGFloat = 55
    static let rowHeight: CGFloat = 58
    static let listVerticalPadding: CGFloat = 7
    static let statusHeight: CGFloat = 205
    static let maximumVisibleRows = 7

    static let compactCornerRadius: CGFloat = searchHeight / 2
    static let expandedCornerRadius: CGFloat = 16

    /// What the expanded area below the search field shows.
    enum ExpandedContent: Equatable {
        case results(rowCount: Int)
        case status

        var height: CGFloat {
            switch self {
            case .results(let rowCount):
                let visibleRows = min(max(rowCount, 0), LauncherLayout.maximumVisibleRows)
                return LauncherLayout.listVerticalPadding * 2
                    + CGFloat(visibleRows) * LauncherLayout.rowHeight
            case .status:
                return LauncherLayout.statusHeight
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
    let onLaunch: (AppDescriptor) -> Void
    let onDismiss: () -> Void

    @FocusState private var isSearchFocused: Bool

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
                results
                    .frame(height: max(0, animation.currentHeight - LauncherLayout.searchHeight - 1))
            }
        }
        .frame(width: LauncherLayout.width, height: animation.currentHeight)
        .launcherPanelSurface(cornerRadius: animation.cornerRadius)
        .onAppear { isSearchFocused = true }
        .onReceive(viewModel.$focusRequest.dropFirst()) { _ in
            isSearchFocused = true
        }
        .onExitCommand(perform: onDismiss)
        .onMoveCommand { direction in
            switch direction {
            case .up: viewModel.moveSelection(by: -1)
            case .down: viewModel.moveSelection(by: 1)
            default: break
            }
        }
    }

    private var searchBar: some View {
        HStack(spacing: 14) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 28, weight: .regular))
                .foregroundStyle(.secondary)
                .frame(width: 28)

            TextField("聚焦搜索", text: $viewModel.query)
                .textFieldStyle(.plain)
                .font(.system(size: 24, weight: .regular))
                .tint(.primary)
                .focused($isSearchFocused)
                .onSubmit {
                    guard let app = viewModel.selectedApp else { return }
                    onLaunch(app)
                }

            if viewModel.isLoading {
                ProgressView()
                    .controlSize(.small)
            } else if !viewModel.query.isEmpty {
                Button {
                    viewModel.query = ""
                    isSearchFocused = true
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.glass)
                .controlSize(.small)
                .help("清除搜索")
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
            if let errorMessage = viewModel.errorMessage, viewModel.apps.isEmpty {
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
            } else if viewModel.isLoading && viewModel.apps.isEmpty {
                VStack(spacing: 10) {
                    ProgressView()
                    Text("正在加载应用…")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if viewModel.filteredApps.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "app.dashed")
                        .font(.system(size: 28))
                        .foregroundStyle(.secondary)
                    Text("没有找到匹配的 App")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                LauncherResultsList(
                    apps: viewModel.filteredApps,
                    selectedIndex: viewModel.selectedIndex,
                    resetRequest: viewModel.listResetRequest,
                    iconProvider: iconProvider,
                    onLaunch: onLaunch
                )
            }
        }
    }
}
