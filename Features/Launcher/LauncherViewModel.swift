import Combine
import CoreGraphics
import Foundation

@MainActor
final class LauncherViewModel: ObservableObject {
    /// How long a snapshot stays fresh before a panel show triggers a rescan.
    static let refreshInterval: TimeInterval = 600
    /// Section title shown above file and folder results.
    static let fileSectionTitle = "文件与文件夹"
    /// 流式增量合并上屏的间隔：避免每个 token 都触发整段 Markdown 重新解析与重绘。
    static let quickAIFlushInterval: Duration = .milliseconds(50)

    @Published var query = "" {
        didSet {
            // Quick AI 模式下改动问题即丢弃旧回答、回到输入态，按 Enter 以新问题重新提问；
            // 输入态不做应用与文件检索。
            if query != oldValue {
                discardQuickAISession()
            }
            guard !isQuickAIModeActive else { return }
            refreshSearchResults()
        }
    }
    @Published private(set) var apps: [AppDescriptor] = []
    @Published private(set) var filteredApps: [AppDescriptor] = []
    @Published private(set) var fileResults: [FileDescriptor] = [] {
        // 文件结果异步到达时列表可能变短：光标仍在范围内则不动，越界则贴到最后一条，空列表归零。
        didSet { selectedIndex = min(selectedIndex, max(results.count - 1, 0)) }
    }
    @Published private(set) var quickQueryResult: QuickQueryResult?
    @Published private(set) var webURLResult: URL?
    @Published private(set) var selectedIndex = 0
    @Published private(set) var isActionSheetVisible = false
    @Published private(set) var selectedActionIndex = 0
    @Published private(set) var listResetRequest = 0
    @Published private(set) var focusRequest = 0
    @Published private(set) var loadState: LauncherLoadState = .idle
    @Published private(set) var launchState: LauncherLaunchState = .idle {
        // 失败横幅占用结果列表上方的高度，出现或消失时重算面板高度。
        didSet {
            let hadLaunchError: Bool
            if case .failed = oldValue { hadLaunchError = true } else { hadLaunchError = false }
            if hadLaunchError != (launchErrorMessage != nil) { updatePanelHeight() }
        }
    }
    @Published private(set) var fileSearchState: LauncherFileSearchState = .idle
    @Published private(set) var panelHeight = LauncherLayout.searchHeight
    /// Tab 切入的 Quick AI 模式：输入框改为提问，`quickAISession` 只在该模式下存在。
    @Published private(set) var isQuickAIModeActive = false
    @Published private(set) var quickAISession: QuickAISession?
    @Published private(set) var quickAIScrollRequest = QuickAIScrollRequest()

    private let discoverApplications: DiscoverApplications
    private let launchApplication: LaunchApplication
    private let searchFiles: SearchFiles?
    private let openFile: OpenFile?
    private let openURL: OpenURL?
    private let askQuickAI: AskQuickAI?
    private let usageStore: any AppUsageStoring
    private let settingsStore: any AppSettingsStoring
    private let aliases: [String: [String]]
    private let fileSearchMinimumQueryLength: Int
    private let fileSearchDebounce: Duration
    private let now: () -> Date

    private var loadTask: Task<Void, Never>?
    private var launchTask: Task<Void, Never>?
    private var fileSearchTask: Task<Void, Never>?
    private var quickAITask: Task<Void, Never>?
    private lazy var quickAIAnswerBuffer = StreamingTextBuffer(interval: LauncherViewModel.quickAIFlushInterval) { [weak self] text in
        self?.quickAISession?.answer += text
        self?.quickAISession?.isAnswerCopied = false
    }
    private var refreshGeneration = 0
    private var fileSearchGeneration = 0
    private var quickAIGeneration = 0
    private var searchIndex = ApplicationSearchIndex()
    private var usageRecords: [String: AppUsageRecord] = [:]
    private var lastRefreshedAt: Date?
    private var catalogIsDirty = false

    init(
        discoverApplications: DiscoverApplications,
        launchApplication: LaunchApplication,
        searchFiles: SearchFiles? = nil,
        openFile: OpenFile? = nil,
        openURL: OpenURL? = nil,
        askQuickAI: AskQuickAI? = nil,
        usageStore: any AppUsageStoring = MemoryAppUsageStore(),
        settingsStore: any AppSettingsStoring = MemoryAppSettingsStore(),
        aliases: [String: [String]] = [:],
        fileSearchMinimumQueryLength: Int = 2,
        fileSearchDebounce: Duration = .milliseconds(120),
        now: @escaping () -> Date = { Date() }
    ) {
        self.discoverApplications = discoverApplications
        self.launchApplication = launchApplication
        self.searchFiles = searchFiles
        self.openFile = openFile
        self.openURL = openURL
        self.askQuickAI = askQuickAI
        self.usageStore = usageStore
        self.settingsStore = settingsStore
        self.aliases = aliases
        self.fileSearchMinimumQueryLength = fileSearchMinimumQueryLength
        self.fileSearchDebounce = fileSearchDebounce
        self.now = now
    }

    deinit {
        loadTask?.cancel()
        launchTask?.cancel()
        fileSearchTask?.cancel()
        quickAITask?.cancel()
    }

    /// Web URLs first (直达), then quick queries, applications and files.
    var results: [SearchResult] {
        (webURLResult.map { [.webURL($0)] } ?? [])
            + (quickQueryResult.map { [.quickQuery($0)] } ?? [])
            + filteredApps.map(SearchResult.application)
            + fileResults.map(SearchResult.file)
    }

    /// Display rows: the file section gets a header, the application section does not.
    var rows: [LauncherRow] {
        var rows = webURLResult.map { [LauncherRow.result(.webURL($0))] } ?? []
        rows += quickQueryResult.map { [LauncherRow.result(.quickQuery($0))] } ?? []
        rows += filteredApps.map { LauncherRow.result(.application($0)) }
        if !fileResults.isEmpty {
            rows.append(.sectionHeader(Self.fileSectionTitle))
            rows += fileResults.map { .result(.file($0)) }
        }
        return rows
    }

    var selectedResult: SearchResult? {
        // Quick AI 模式下没有选中结果，结果相关快捷键（Cmd+F/Y/K 等）随之静默。
        guard isExpanded, !isQuickAIModeActive, results.indices.contains(selectedIndex) else { return nil }
        return results[selectedIndex]
    }

    var selectedApp: AppDescriptor? {
        guard case .application(let app)? = selectedResult else { return nil }
        return app
    }

    /// Index of the selected result within `rows` (accounts for the file section header).
    var selectedRowIndex: Int {
        let frontCount = (webURLResult == nil ? 0 : 1) + (quickQueryResult == nil ? 0 : 1)
        return selectedIndex < frontCount + filteredApps.count
            ? selectedIndex
            : selectedIndex + 1
    }

    var isLoading: Bool {
        if case .loading = loadState { return true }
        return false
    }

    var isSearchingFiles: Bool {
        if case .searching = fileSearchState { return true }
        return false
    }

    /// Whether the panel is expanded (Spotlight collapses to a capsule with an empty query).
    /// 纯空白输入按空查询处理（搜索计划 §8.3）；Quick AI 输入问题时保持胶囊，有回答时展开。
    var isExpanded: Bool {
        quickAISession != nil || (!isQuickAIModeActive && !normalizedQuery.isEmpty)
    }
    /// What the expanded area shows; kept here so view and window share one source of truth.
    var expandedContent: LauncherLayout.ExpandedContent {
        if quickAISession != nil {
            return .quickAI
        }
        if quickQueryResult == nil && webURLResult == nil && (
            (errorMessage != nil && apps.isEmpty)
                || (isLoading && apps.isEmpty)
                || (filteredApps.isEmpty && fileResults.isEmpty)
        ) {
            return .status
        }
        return .results(
            rowCount: results.count,
            sectionHeaderCount: fileResults.isEmpty ? 0 : 1,
            minHeight: isActionSheetVisible ? LauncherLayout.actionSheetMinHeight : 0,
            hasLaunchError: launchErrorMessage != nil
        )
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

                // 历史记录始终加载为内存缓存；是否参与排序由检索期按设置决定。
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
                // 选中的结果仍在就保持选中，选中项已不在时才归零并滚回顶部。
                if !self.updateFilteredApps(preservingSelection: true) {
                    self.requestListReset()
                }
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

    /// Opens a result: web URLs through the default browser, applications launch
    /// through the catalog, files through the default app.
    @discardableResult
    func open(_ result: SearchResult) -> Task<Void, Never>? {
        switch result {
        case .application(let application):
            return launch(application)
        case .file(let file):
            return open(file)
        case .webURL(let url):
            return openExternalURL(url)
        case .quickQuery:
            return nil
        }
    }

    /// Searches the current query with the default browser (`Cmd+Enter`).
    @discardableResult
    func searchWeb() -> Task<Void, Never>? {
        let text = normalizedQuery
        guard !text.isEmpty, let searchURL = WebURLResolver.searchURL(for: text) else { return nil }
        return openExternalURL(searchURL)
    }

    /// Reveals the selected item in Finder (`Cmd+F`).
    func reveal(_ result: SearchResult) {
        guard let url = result.url, url.isFileURL else { return }
        openFile?.reveal(url: url)
    }

    /// Opens the item's directory in Terminal (`Cmd+K` action menu).
    func openInTerminal(url: URL) {
        openFile?.openInTerminal(url: url)
    }

    /// Publishes a failure directly when an item cannot be opened or located.
    func publishFileOpenError(fileName: String, reason: String) {
        launchState = .failed(LauncherErrorMessage.message(
            for: ApplicationError.fileOpenFailed(fileName: fileName, reason: reason)
        ))
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
        isActionSheetVisible = false
        stopQuickAI()
        loadTask?.cancel()
        launchTask?.cancel()
        fileSearchTask?.cancel()
        if isLoading { loadState = .idle }
        if isLaunching { launchState = .idle }
        if isSearchingFiles { fileSearchState = .idle }
    }

    func prepareForPresentation() {
        isActionSheetVisible = false
        discardQuickAISession()
        isQuickAIModeActive = false
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
        guard !isQuickAIModeActive else { return }
        let count = results.count
        guard count > 0 else { return }
        let newIndex = min(max(selectedIndex + offset, 0), count - 1)
        guard newIndex != selectedIndex else { return }
        let wasActionSheetVisible = isActionSheetVisible
        isActionSheetVisible = false
        selectedIndex = newIndex
        if wasActionSheetVisible {
            updatePanelHeight()
        }
    }

    /// Answer text to copy (`Enter` / `Cmd+C`) without `<think>` reasoning;
    /// nil until some visible content has arrived.
    var quickAIAnswerToCopy: String? {
        guard let answer = quickAISession.map({ QuickAIMarkdown.removingThinking(from: $0.answer) }),
              !answer.isEmpty else { return nil }
        return answer
    }

    /// Scrolls the answer area one step (`↑` / `↓` in Quick AI).
    func scrollQuickAIAnswer(by direction: Int) {
        guard quickAISession != nil else { return }
        quickAIScrollRequest = QuickAIScrollRequest(
            direction: direction,
            serial: quickAIScrollRequest.serial &+ 1
        )
    }

    /// Switches between search and Quick AI mode (`Tab`). The typed text is kept,
    /// so it becomes the question draft or the search query again.
    func toggleQuickAIMode() {
        if isQuickAIModeActive {
            discardQuickAISession()
            isQuickAIModeActive = false
            refreshSearchResults()
        } else {
            guard askQuickAI != nil else { return }
            isActionSheetVisible = false
            isQuickAIModeActive = true
            updatePanelHeight()
        }
    }

    /// Asks the current query as a Quick AI question (`Enter` in Quick AI mode) and
    /// streams the answer into `quickAISession`. Returns nil when there is nothing to ask.
    @discardableResult
    func startQuickAI() -> Task<Void, Never>? {
        let question = normalizedQuery
        guard let askQuickAI, isQuickAIModeActive, !question.isEmpty else { return nil }

        stopQuickAI()
        quickAIGeneration += 1
        let generation = quickAIGeneration
        isActionSheetVisible = false
        quickAISession = QuickAISession(question: question)
        updatePanelHeight()

        let task = Task { [weak self] in
            do {
                try await askQuickAI.execute(question: question) { delta in
                    guard let self, self.quickAIGeneration == generation else { return }
                    self.quickAIAnswerBuffer.append(delta)
                }
                guard let self, self.quickAIGeneration == generation else { return }
                self.quickAIAnswerBuffer.flush()
                self.quickAISession?.state = .finished
            } catch {
                // 中断（Esc、隐藏面板、改动输入）会递增 generation，取消带来的错误在此丢弃。
                guard let self, self.quickAIGeneration == generation else { return }
                self.quickAIAnswerBuffer.flush()
                self.quickAISession?.state = .failed(LauncherErrorMessage.message(for: error))
            }

            if let self, self.quickAIGeneration == generation {
                self.quickAITask = nil
            }
        }
        quickAITask = task
        return task
    }

    /// Interrupts an in-flight answer but keeps what has arrived on screen,
    /// so hiding the panel does not resize it mid fade-out.
    func stopQuickAI() {
        guard quickAITask != nil else { return }
        quickAIGeneration += 1
        quickAITask?.cancel()
        quickAITask = nil
        quickAIAnswerBuffer.flush()
        if quickAISession?.isStreaming == true {
            quickAISession?.state = .finished
        }
    }

    func markQuickAIAnswerCopied() {
        quickAISession?.isAnswerCopied = true
    }

    var currentAvailableActions: [ResultMenuAction] {
        guard let selectedResult else { return [] }
        return LauncherActionMenu.availableActions(for: selectedResult)
    }

    var selectedAction: ResultMenuAction? {
        let actions = currentAvailableActions
        guard actions.indices.contains(selectedActionIndex) else { return nil }
        return actions[selectedActionIndex]
    }

    func toggleActionSheet() {
        let actions = currentAvailableActions
        guard !actions.isEmpty else {
            if isActionSheetVisible {
                isActionSheetVisible = false
                updatePanelHeight()
            }
            return
        }
        if isActionSheetVisible {
            isActionSheetVisible = false
        } else {
            selectedActionIndex = 0
            isActionSheetVisible = true
        }
        updatePanelHeight()
    }

    func dismissActionSheet() {
        guard isActionSheetVisible else { return }
        isActionSheetVisible = false
        updatePanelHeight()
    }

    func moveActionSelection(by delta: Int) {
        let actions = currentAvailableActions
        guard !actions.isEmpty else { return }
        let count = actions.count
        let nextIndex = (selectedActionIndex + delta + count) % count
        selectedActionIndex = nextIndex
    }

    @discardableResult
    private func open(_ file: FileDescriptor) -> Task<Void, Never>? {
        guard launchTask == nil else { return launchTask }
        guard let openFile else { return nil }

        launchState = .launching
        launchTask = Task { [weak self] in
            do {
                try await openFile.execute(file)
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

    /// Opens a web URL in the default browser, sharing the launch pipeline so
    /// concurrent triggers are guarded and failures surface as launch errors.
    @discardableResult
    private func openExternalURL(_ url: URL) -> Task<Void, Never>? {
        guard launchTask == nil else { return launchTask }
        guard let openURL else { return nil }

        launchState = .launching
        launchTask = Task { [weak self] in
            do {
                try await openURL.execute(url)
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

    /// Drops the current answer; Quick AI mode itself stays as it is.
    private func discardQuickAISession() {
        stopQuickAI()
        quickAIAnswerBuffer.discard()
        guard quickAISession != nil else { return }
        quickAISession = nil
        updatePanelHeight()
    }

    private func refreshSearchResults() {
        isActionSheetVisible = false
        if case .failed = launchState {
            launchState = .idle
        }
        quickQueryResult = QuickQueryResolver.resolve(query)
        webURLResult = WebURLResolver.recognize(query)
        scheduleFileSearch()
        updateFilteredApps()
        requestListReset()
    }

    private func finishLaunching() {
        launchTask = nil
    }

    private var normalizedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var shouldRefreshAutomatically: Bool {
        if apps.isEmpty { return true }
        if catalogIsDirty { return true }
        guard let lastRefreshedAt else { return true }
        return now().timeIntervalSince(lastRefreshedAt) >= Self.refreshInterval
    }

    private func recordUsage(for application: AppDescriptor) {
        guard settingsStore.load().isUsageRankingEnabled else { return }
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

    /// 重新筛选应用；返回是否保留了原选择，未保留时选择归零。`preservingSelection` 用于后台目录刷新：
    /// 选中的结果仍在时保持选中与操作菜单，避免用户正用方向键挑选时被拉回第一项、回车打开别的应用。
    @discardableResult
    private func updateFilteredApps(preservingSelection: Bool = false) -> Bool {
        let previousSelectionID = preservingSelection ? selectedResult?.id : nil
        let normalizedQuery = self.normalizedQuery
        let effectiveUsage = settingsStore.load().isUsageRankingEnabled ? usageRecords : [:]
        filteredApps = normalizedQuery.isEmpty
            ? apps
            : searchIndex.search(query: normalizedQuery, usage: effectiveUsage, now: now())

        if let previousSelectionID,
           let index = results.firstIndex(where: { $0.id == previousSelectionID }) {
            selectedIndex = index
            updatePanelHeight()
            return true
        }
        // 选择归零会让展开中的操作菜单目标漂移，必须同步收起。
        isActionSheetVisible = false
        selectedIndex = 0
        updatePanelHeight()
        return false
    }

    /// Debounced file lookup; stale results are dropped by generation so the
    /// newest query always wins. Failures leave the file section empty.
    /// 检索期间保留上一批文件结果（与原生 Spotlight 一致），否则每敲一个字
    /// 面板都会先塌成状态页再弹回列表，快速输入时剧烈抖动。只保留名称仍包含
    /// 新查询的条目，回车才不会打开与当前输入不符的旧文件。
    private func scheduleFileSearch() {
        fileSearchTask?.cancel()
        fileSearchTask = nil
        fileSearchGeneration += 1
        let generation = fileSearchGeneration

        let normalizedQuery = self.normalizedQuery
        guard let searchFiles,
              settingsStore.load().isFileSearchEnabled,
              normalizedQuery.count >= fileSearchMinimumQueryLength else {
            if !fileResults.isEmpty { fileResults = [] }
            fileSearchState = .idle
            return
        }

        let stillMatching = fileResults.filter {
            $0.name.range(
                of: normalizedQuery,
                options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]
            ) != nil
        }
        if stillMatching.count != fileResults.count { fileResults = stillMatching }
        fileSearchState = .searching
        let debounce = fileSearchDebounce
        fileSearchTask = Task { [weak self] in
            do {
                try await Task.sleep(for: debounce)
                let files = try await searchFiles.execute(query: normalizedQuery)
                guard let self, self.fileSearchGeneration == generation else { return }
                self.fileResults = files
                self.fileSearchState = .loaded
                self.updatePanelHeight()
            } catch is CancellationError {
                // 仅 cancelOperations() 会在不递增 generation 的情况下取消，此时保持 idle。
                guard let self, self.fileSearchGeneration == generation else { return }
                self.fileSearchState = .idle
            } catch {
                guard let self, self.fileSearchGeneration == generation else { return }
                self.fileResults = []
                self.fileSearchState = .loaded
                self.updatePanelHeight()
            }

            if let self, self.fileSearchGeneration == generation {
                self.fileSearchTask = nil
            }
        }
    }

    private func updatePanelHeight() {
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
        case .fileSearchFailed(let reason):
            return "无法搜索文件：\(reason)"
        case .fileOpenFailed(let fileName, let reason):
            return "无法打开 \(fileName)：\(reason)"
        case .urlOpenFailed(let reason):
            return "无法打开链接：\(reason)"
        case .quickAINotConfigured:
            return "请先在「设置… → Quick AI」中填写接口地址与模型。"
        case .quickAIFailed(let reason):
            return "回答失败：\(reason)"
        }
    }
}
