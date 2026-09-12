import Combine
import CoreGraphics
import Foundation

@MainActor
final class LauncherViewModel: ObservableObject {
    /// How long a snapshot stays fresh before a panel show triggers a rescan.
    static let refreshInterval: TimeInterval = 600

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
    private let usageStore: any AppUsageStoring
    private let aliases: [String: [String]]
    private let now: () -> Date

    private var loadTask: Task<Void, Never>?
    private var launchTask: Task<Void, Never>?
    private var refreshGeneration = 0
    private var searchIndex = ApplicationSearchIndex()
    private var usageRecords: [String: AppUsageRecord] = [:]
    private var lastRefreshedAt: Date?
    private var catalogIsDirty = false

    init(
        discoverApplications: DiscoverApplications,
        launchApplication: LaunchApplication,
        usageStore: any AppUsageStoring = MemoryAppUsageStore(),
        aliases: [String: [String]] = [:],
        now: @escaping () -> Date = { Date() }
    ) {
        self.discoverApplications = discoverApplications
        self.launchApplication = launchApplication
        self.usageStore = usageStore
        self.aliases = aliases
        self.now = now
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
    /// 纯空白输入按空查询处理（搜索计划 §8.3）。
    var isExpanded: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
        if loadTask != nil { return loadTask }
        if case .loaded = loadState { return nil }
        return refreshApplications(force: true)
    }

    /// Starts a background snapshot refresh. A forced refresh cancels an
    /// in-flight scan so the newest request wins (search plan §11); an automatic
    /// one only starts when the snapshot is empty, stale or dirty.
    @discardableResult
    func refreshApplications(force: Bool) -> Task<Void, Never>? {
        if let loadTask {
            guard force else { return loadTask }
            loadTask.cancel()
        } else if !force, !shouldRefreshAutomatically {
            return nil
        }

        refreshGeneration += 1
        let generation = refreshGeneration
        loadState = .loading

        let discoverApplications = self.discoverApplications
        let usageStore = self.usageStore
        let aliases = self.aliases

        let task = Task { [weak self] in
            do {
                let descriptors = try await discoverApplications.execute()
                try Task.checkCancellation()

                let usage = await usageStore.records()
                let index = await Task.detached(priority: .userInitiated) {
                    ApplicationSearchIndex(applications: descriptors, aliases: aliases)
                }.value

                guard let self, self.refreshGeneration == generation else { return }
                self.apps = descriptors
                self.searchIndex = index
                self.usageRecords = usage
                self.lastRefreshedAt = self.now()
                self.catalogIsDirty = false
                self.loadState = .loaded
                self.updateFilteredApps()
                self.requestListReset()
                // 空扫描结果（如目录临时异常）不作为清理依据，防止误清全部使用历史。
                // 不能用 guard-return：会跳过下方 loadTask 清理，阻塞后续刷新。
                if !descriptors.isEmpty {
                    self.pruneUsageRecords(keepingKeys: descriptors.map(\.usageKey))
                }
            } catch is CancellationError {
                guard let self, self.refreshGeneration == generation else { return }
                self.loadState = self.apps.isEmpty ? .idle : .loaded
            } catch {
                guard let self, self.refreshGeneration == generation else { return }
                self.loadState = .failed(LauncherErrorMessage.message(for: error))
            }

            if let self, self.refreshGeneration == generation {
                self.loadTask = nil
            }
        }
        loadTask = task
        return task
    }

    @discardableResult
    func launch(_ application: AppDescriptor) -> Task<Void, Never>? {
        guard launchTask == nil else { return launchTask }

        launchState = .launching
        let launchApplication = self.launchApplication

        launchTask = Task { [weak self] in
            do {
                try await launchApplication.execute(application)
                self?.recordUsage(for: application)
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
        refreshApplications(force: false)
    }

    /// Marks the catalog for refresh on the next panel show (directory watcher).
    func markCatalogDirty() {
        catalogIsDirty = true
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

    private func finishLaunching() {
        launchTask = nil
    }

    private var shouldRefreshAutomatically: Bool {
        if apps.isEmpty { return true }
        if catalogIsDirty { return true }
        guard let lastRefreshedAt else { return true }
        return now().timeIntervalSince(lastRefreshedAt) >= Self.refreshInterval
    }

    private func recordUsage(for application: AppDescriptor) {
        let key = application.usageKey
        let usageStore = self.usageStore
        Task { [weak self] in
            await usageStore.recordLaunch(key: key)
            self?.usageRecords = await usageStore.records()
        }
    }

    private func pruneUsageRecords(keepingKeys: [String]) {
        let usageStore = self.usageStore
        Task { [weak self] in
            await usageStore.prune(keeping: keepingKeys)
            self?.usageRecords = await usageStore.records()
        }
    }

    private func updateFilteredApps() {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        filteredApps = normalizedQuery.isEmpty
            ? apps
            : searchIndex.search(query: normalizedQuery, usage: usageRecords, now: now())

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

    private static func message(for applicationError: ApplicationError) -> String {
        switch applicationError {
        case .discoveryFailed(let reason):
            return "无法加载应用列表：\(reason)"
        case .launchFailed(let applicationName, let reason):
            return "无法启动 \(applicationName)：\(reason)"
        }
    }
}
