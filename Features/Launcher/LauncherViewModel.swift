import Combine
import CoreGraphics
import Foundation

@MainActor
final class LauncherViewModel: ObservableObject {
    @Published var query = "" {
        didSet {
            updateFilteredApps()
            requestListReset()
        }
    }
    @Published private(set) var apps: [AppDescriptor] = []
    @Published private(set) var filteredApps: [AppDescriptor] = []
    @Published private(set) var selectedIndex = 0
    @Published private(set) var listResetRequest = 0
    @Published private(set) var focusRequest = 0
    @Published private(set) var loadState: LauncherLoadState = .idle
    @Published private(set) var launchState: LauncherLaunchState = .idle
    @Published private(set) var panelHeight = LauncherLayout.searchHeight

    private let discoverApplications: DiscoverApplications
    private let launchApplication: LaunchApplication
    private var loadTask: Task<Void, Never>?
    private var launchTask: Task<Void, Never>?

    init(
        discoverApplications: DiscoverApplications,
        launchApplication: LaunchApplication
    ) {
        self.discoverApplications = discoverApplications
        self.launchApplication = launchApplication
    }

    deinit {
        loadTask?.cancel()
        launchTask?.cancel()
    }

    var selectedApp: AppDescriptor? {
        guard isExpanded, filteredApps.indices.contains(selectedIndex) else { return nil }
        return filteredApps[selectedIndex]
    }

    var isLoading: Bool {
        if case .loading = loadState { return true }
        return false
    }

    /// Whether the panel is expanded (Spotlight collapses to a capsule with an empty query).
    var isExpanded: Bool {
        !query.isEmpty
    }

    /// What the expanded area shows; kept here so view and window share one source of truth.
    var expandedContent: LauncherLayout.ExpandedContent {
        if (errorMessage != nil && apps.isEmpty)
            || (isLoading && apps.isEmpty)
            || filteredApps.isEmpty {
            return .status
        }
        return .results(rowCount: filteredApps.count)
    }

    var errorMessage: String? {
        guard case .failed(let message) = loadState else { return nil }
        return message
    }

    var isLaunching: Bool {
        if case .launching = launchState { return true }
        return false
    }

    var launchErrorMessage: String? {
        guard case .failed(let message) = launchState else { return nil }
        return message
    }

    @discardableResult
    func loadApps() -> Task<Void, Never>? {
        guard loadTask == nil else { return loadTask }
        if case .loaded = loadState { return nil }

        loadState = .loading
        let discoverApplications = self.discoverApplications

        loadTask = Task { [weak self] in
            do {
                let descriptors = try await discoverApplications.execute()
                try Task.checkCancellation()

                guard let self else { return }
                apps = descriptors
                updateFilteredApps()
                requestListReset()
                loadState = .loaded
            } catch is CancellationError {
                self?.loadState = .idle
            } catch {
                self?.loadState = .failed(LauncherErrorMessage.message(for: error))
            }

            self?.finishLoading()
        }

        return loadTask
    }

    @discardableResult
    func launch(_ application: AppDescriptor) -> Task<Void, Never>? {
        guard launchTask == nil else { return launchTask }

        launchState = .launching
        let launchApplication = self.launchApplication

        launchTask = Task { [weak self] in
            do {
                try await launchApplication.execute(application)
                self?.launchState = .idle
            } catch is CancellationError {
                self?.launchState = .idle
            } catch {
                self?.launchState = .failed(LauncherErrorMessage.message(for: error))
            }

            self?.finishLaunching()
        }

        return launchTask
    }

    func cancelOperations() {
        loadTask?.cancel()
        launchTask?.cancel()
        if isLoading { loadState = .idle }
        if isLaunching { launchState = .idle }
    }

    func prepareForPresentation() {
        query = ""
    }

    func requestFocus() {
        focusRequest &+= 1
    }

    func moveSelection(by offset: Int) {
        guard !filteredApps.isEmpty else { return }
        let newIndex = min(max(selectedIndex + offset, 0), filteredApps.count - 1)
        guard newIndex != selectedIndex else { return }
        selectedIndex = newIndex
    }

    private func finishLoading() {
        loadTask = nil
    }

    private func finishLaunching() {
        launchTask = nil
    }

    private func updateFilteredApps() {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        filteredApps = normalizedQuery.isEmpty
            ? apps
            : apps.filter { $0.name.localizedCaseInsensitiveContains(normalizedQuery) }

        selectedIndex = 0
        panelHeight = LauncherLayout.totalHeight(
            isExpanded: isExpanded,
            content: isExpanded ? expandedContent : nil
        )
    }

    private func requestListReset() {
        listResetRequest &+= 1
    }
}

private enum LauncherErrorMessage {
    static func message(for error: Error) -> String {
        switch error {
        case let applicationError as ApplicationError:
            return message(for: applicationError)
        default:
            return "操作未能完成，请重试。"
        }
    }

    private static func message(for error: ApplicationError) -> String {
        switch error {
        case .discoveryFailed(let reason):
            return "无法加载应用列表：\(reason)"
        case .launchFailed(let applicationName, let reason):
            return "无法启动 \(applicationName)：\(reason)"
        }
    }
}
