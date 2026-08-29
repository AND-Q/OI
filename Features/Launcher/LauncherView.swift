import Combine
import SwiftUI

@MainActor
struct LauncherView: View {
    @ObservedObject var viewModel: LauncherViewModel
    let iconProvider: any ApplicationIconProviding
    let onLaunch: (AppDescriptor) -> Void
    let onDismiss: () -> Void

    @FocusState private var isSearchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            Divider()
            results
        }
        .frame(width: 640, height: 386)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.white.opacity(0.22), lineWidth: 1)
        }
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
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 21, weight: .medium))
                .foregroundStyle(.secondary)

            TextField("搜索 App", text: $viewModel.query)
                .textFieldStyle(.plain)
                .font(.system(size: 22, weight: .regular))
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
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("清除搜索")
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 17)
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
                    .buttonStyle(.bordered)
                }
                .frame(maxWidth: .infinity, minHeight: 323)
            } else if viewModel.isLoading && viewModel.apps.isEmpty {
                VStack(spacing: 10) {
                    ProgressView()
                    Text("正在加载应用…")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 323)
            } else if viewModel.filteredApps.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "app.dashed")
                        .font(.system(size: 28))
                        .foregroundStyle(.secondary)
                    Text("没有找到匹配的 App")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 323)
            } else {
                LauncherResultsList(
                    apps: viewModel.filteredApps,
                    selectedIndex: viewModel.selectedIndex,
                    resetRequest: viewModel.listResetRequest,
                    iconProvider: iconProvider,
                    onLaunch: onLaunch
                )
                .frame(height: 323)
            }
        }
    }
}
