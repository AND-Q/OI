import Combine
import CoreGraphics
import Foundation

@MainActor
final class LauncherViewModel: ObservableObject {
    /// 应用快照的有效期：超过后再次呼出面板时重新扫描。
    static let refreshInterval: TimeInterval = 600
    /// 文件与文件夹结果上方的分组标题。
    static let fileSectionTitle = String(localized: "文件与文件夹")
    /// 流式增量合并上屏的间隔：避免每个 token 都触发整段 Markdown 重新解析与重绘。
    static let quickAIFlushInterval: Duration = .milliseconds(50)
    /// 追问框右端「已复制」的显示时长。
    static let quickAICopiedHintDuration: Duration = .seconds(2)
    /// 收起面板后保留 Quick AI 对话的时长：在此之内再次呼出直接回到这段对话。
    static let quickAIRestoreInterval: TimeInterval = 300

    @Published var query = "" {
        didSet {
            // Quick AI 模式下输入框只是在写问题或下一条追问，不清空已有回答，也不做应用与文件检索。
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
    /// 路径直达：输入以 `/` 或 `~` 开头且实际存在的路径时置顶显示的文件或文件夹。
    @Published private(set) var pathResult: FileDescriptor?
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
    /// 再次呼出回到上一段对话时递增，回答区据此滚到最后一轮的顶部。
    @Published private(set) var quickAIRestoreRequest = 0

    private let discoverApplications: DiscoverApplications
    private let launchApplication: LaunchApplication
    private let searchFiles: SearchFiles?
    private let openFile: OpenFile?
    private let openURL: OpenURL?
    private let askQuickAI: AskQuickAI?
    private let usageStore: any AppUsageStoring
    private let settingsStore: any AppSettingsStoring
    private let notifier: any UserNotifying
    private let quickQueryResolver: QuickQueryResolver
    private let aliases: [String: [String]]
    private let fileSearchMinimumQueryLength: Int
    private let fileSearchDebounce: Duration
    private let now: () -> Date

    private var loadTask: Task<Void, Never>?
    private var fileSearchTask: Task<Void, Never>?
    private var pathLookupTask: Task<Void, Never>?
    private var quickAICopiedHintTask: Task<Void, Never>?
    /// 带着 Quick AI 对话收起面板的时间；对话结束或重新回到面板时清除。
    private var quickAIClosedAt: Date?
    private lazy var quickAIRequest = StreamingRequest(flushInterval: LauncherViewModel.quickAIFlushInterval) { [weak self] text in
        self?.quickAISession?.lastTurn.answer += text
        self?.quickAISession?.isAnswerCopied = false
    }
    private var refreshGeneration = 0
    private var fileSearchGeneration = 0
    private var pathLookupGeneration = 0
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
        notifier: any UserNotifying = MemoryUserNotifier(),
        ipAddressProvider: any LocalIPAddressProviding = MemoryLocalIPAddressProvider(),
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
        self.notifier = notifier
        self.quickQueryResolver = QuickQueryResolver(ipAddressProvider: ipAddressProvider)
        self.aliases = aliases
        self.fileSearchMinimumQueryLength = fileSearchMinimumQueryLength
        self.fileSearchDebounce = fileSearchDebounce
        self.now = now
    }

    deinit {
        loadTask?.cancel()
        fileSearchTask?.cancel()
        pathLookupTask?.cancel()
    }

    /// 全部结果：网址与路径直达在前，其后依次是快速查询、应用与文件。
    var results: [SearchResult] {
        resultsAboveFiles + fileResults.map(SearchResult.file)
    }

    /// 列表显示的行：文件分组带标题，应用分组不带。
    var rows: [LauncherRow] {
        var rows = resultsAboveFiles.map(LauncherRow.result)
        if !fileResults.isEmpty {
            rows.append(.sectionHeader(Self.fileSectionTitle))
            rows += fileResults.map { .result(.file($0)) }
        }
        return rows
    }

    /// 文件分组之前的结果：直达、快速查询与应用。`results` 与 `rows` 共用这一排列顺序。
    private var resultsAboveFiles: [SearchResult] {
        (webURLResult.map { [.webURL($0)] } ?? [])
            + (pathResult.map { [.file($0)] } ?? [])
            + (quickQueryResult.map { [.quickQuery($0)] } ?? [])
            + filteredApps.map(SearchResult.application)
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

    /// 选中结果在 `rows` 中的位置（计入文件分组标题这一行）。
    var selectedRowIndex: Int {
        selectedIndex < results.count - fileResults.count ? selectedIndex : selectedIndex + 1
    }

    var isLoading: Bool {
        if case .loading = loadState { return true }
        return false
    }

    var isSearchingFiles: Bool {
        if case .searching = fileSearchState { return true }
        return false
    }

    /// 面板是否展开（与聚焦搜索一致，输入为空时收成胶囊）。
    /// 纯空白输入按空查询处理（搜索计划 §8.3）；Quick AI 输入问题时保持胶囊，有回答时展开。
    var isExpanded: Bool {
        quickAISession != nil || (!isQuickAIModeActive && !normalizedQuery.isEmpty)
    }
    /// 展开区域显示的内容；放在这里，视图与窗口尺寸以同一处判断为准。
    var expandedContent: LauncherLayout.ExpandedContent {
        if quickAISession != nil {
            return .quickAI
        }
        if quickQueryResult == nil && webURLResult == nil && pathResult == nil && (
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

    /// 在后台刷新应用快照。强制刷新会取消进行中的扫描，最新的请求胜出（搜索计划 §11）；
    /// 自动刷新只在快照为空、过期或目录有变动时进行。
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

    /// 打开结果：网址经默认浏览器，应用经启动用例，文件用默认 App 打开。
    /// 打开在后台进行、面板随即收起，失败经系统通知告知。
    @discardableResult
    func open(_ result: SearchResult) -> Task<Void, Never>? {
        switch result {
        case .application(let application):
            launch(application)
        case .file(let file):
            open(file)
        case .webURL(let url):
            openExternalURL(url)
        case .quickQuery:
            nil
        }
    }

    /// 用设置中选择的搜索引擎在默认浏览器中搜索当前输入（`Cmd+Enter`）。
    @discardableResult
    func searchWeb() -> Task<Void, Never>? {
        let text = normalizedQuery
        guard !text.isEmpty,
              let searchURL = settingsStore.load().webSearchEngine.searchURL(for: text) else { return nil }
        return openExternalURL(searchURL)
    }

    /// 在 Finder 中显示选中的条目（`Cmd+F`）。
    func reveal(_ result: SearchResult) {
        guard let url = result.url, url.isFileURL else { return }
        openFile?.reveal(url: url)
    }

    /// 在终端中打开条目所在的目录（`Cmd+K` 操作菜单）。
    func openInTerminal(url: URL) {
        openFile?.openInTerminal(url: url)
    }

    /// 「用其他 App 打开…」为文件结果列出的 App，默认 App 在前。
    func applications(toOpen file: FileDescriptor) -> [OpenWithApplication] {
        openFile?.applications(toOpen: file) ?? []
    }

    /// 用选择的 App 在后台打开文件，与默认方式打开一致；失败经系统通知告知。
    @discardableResult
    func open(_ file: FileDescriptor, withApplicationAt applicationURL: URL) -> Task<Void, Never>? {
        guard let openFile else { return nil }
        return Task { [weak self] in
            do {
                try await openFile.execute(file, withApplicationAt: applicationURL)
            } catch {
                self?.notifyOpenFailure(error)
            }
        }
    }

    /// 条目无法打开或定位时直接显示失败横幅。
    func publishFileOpenError(fileName: String, reason: String) {
        launchState = .failed(LauncherErrorMessage.message(
            for: ApplicationError.fileOpenFailed(fileName: fileName, reason: reason)
        ))
    }

    /// 在后台启动应用：面板随即收起，不等应用启动完成（冷启动可能要数秒）。
    /// 每次启动各自进行，前一次尚未完成时重新呼出面板启动其他应用不受影响；
    /// 启动成功才记入使用历史，失败经系统通知告知。
    @discardableResult
    func launch(_ application: AppDescriptor) -> Task<Void, Never>? {
        let launchApplication = self.launchApplication
        return Task { [weak self] in
            do {
                try await launchApplication.execute(application)
                self?.recordUsage(for: application)
            } catch {
                self?.notifyOpenFailure(error)
            }
        }
    }

    func cancelOperations() {
        isActionSheetVisible = false
        stopQuickAI()
        loadTask?.cancel()
        fileSearchTask?.cancel()
        if isLoading { loadState = .idle }
        if isSearchingFiles { fileSearchState = .idle }
    }

    /// 呼出面板前调用：收起后 5 分钟内带着对话再次呼出时回到这段对话（全部轮次与追问框中的草稿），
    /// 否则丢弃对话（中断仍在后台进行的回答）、以空的检索打开。
    func prepareForPresentation() {
        isActionSheetVisible = false
        if let closedAt = quickAIClosedAt, quickAISession != nil,
           now().timeIntervalSince(closedAt) < Self.quickAIRestoreInterval {
            quickAIClosedAt = nil
            quickAIRestoreRequest &+= 1
        } else {
            discardQuickAISession()
            isQuickAIModeActive = false
            query = ""
        }
        refreshApplications(force: false)
    }

    /// 面板收起（呼出快捷键、点到别处）时调用：有对话时记下收起时间，供再次呼出时恢复（见 `prepareForPresentation`）；
    /// 进行中的回答在后台继续输出，回来时看到的是完整的回答。以 `Esc` 等结束对话的方式收起时随后调用
    /// `endQuickAIConversation`。
    func prepareForDismissal() {
        quickAIClosedAt = quickAISession == nil ? nil : now()
    }

    /// `Esc` 与复制并关闭（`Enter`）结束这段对话：中断进行中的回答，面板照常收起，再次呼出时不再恢复；
    /// 对话本身留到下次呼出时才丢弃，避免淡出途中面板高度收缩。
    func endQuickAIConversation() {
        stopQuickAI()
        quickAIClosedAt = nil
    }

    /// 标记应用目录有变动，下次呼出面板时刷新（由目录监听调用）。
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

    /// 复制（`Enter` / `Cmd+C`）用的最后一条回答，不含 `<think>` 推理内容；尚无可见内容时为 nil。
    var quickAIAnswerToCopy: String? {
        quickAISession?.answerToCopy
    }

    /// 回车在 Quick AI 对话中的作用，面板按键与追问框右端的提示共用；尚未提问时为 nil（回车即提问）。
    var quickAIReturnAction: QuickAISession.ReturnAction? {
        quickAISession?.returnAction(hasDraft: !normalizedQuery.isEmpty)
    }

    /// 回答区滚动一步（Quick AI 中的 `↑` / `↓`）。
    func scrollQuickAIAnswer(by direction: Int) {
        guard quickAISession != nil else { return }
        quickAIScrollRequest = QuickAIScrollRequest(
            direction: direction,
            serial: quickAIScrollRequest.serial &+ 1
        )
    }

    /// 在检索与 Quick AI 模式之间切换（`Tab`）。已输入的文字保留，
    /// 切换后成为问题草稿或重新作为检索词。
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

    /// 新对话（`⌘N` 或标题栏的「新对话」）：丢弃当前对话，回到尚未提问的 Quick AI，追问框中的草稿留作新的问题。
    func startNewQuickAIConversation() {
        guard isQuickAIModeActive, quickAISession != nil else { return }
        discardQuickAISession()
    }

    /// 把当前输入作为 Quick AI 问题发送（Quick AI 模式下按 `Enter`）：尚未提问时开始对话，已有对话时作为追问。
    /// 问题移到回答区、输入框清空，回答流式写入最后一轮。没有可发送的内容或上一轮仍在输出时返回 nil。
    @discardableResult
    func startQuickAI() -> Task<Void, Never>? {
        let question = normalizedQuery
        guard askQuickAI != nil, isQuickAIModeActive, !question.isEmpty,
              quickAISession?.isStreaming != true else { return nil }

        if quickAISession == nil {
            let modelName = settingsStore.load().quickAIModel.trimmingCharacters(in: .whitespacesAndNewlines)
            quickAISession = QuickAISession(question: question, modelName: modelName)
        } else {
            quickAISession?.append(question: question)
        }
        query = ""
        return streamLastQuickAITurn()
    }

    /// 重试最后一轮（失败或没有收到回答时按 `Enter`）：沿用这一轮的问题，输入框中的草稿不变。
    /// 没有对话或仍在输出时返回 nil。
    @discardableResult
    func retryQuickAI() -> Task<Void, Never>? {
        guard quickAISession?.isStreaming == false else { return nil }
        quickAISession?.restartLastTurn()
        return streamLastQuickAITurn()
    }

    /// 中断进行中的回答，保留已经到达的内容，避免隐藏面板时在淡出途中改变面板高度。
    func stopQuickAI() {
        guard quickAIRequest.stop() else { return }
        if quickAISession?.isStreaming == true {
            quickAISession?.lastTurn.state = .finished
        }
    }

    func markQuickAIAnswerCopied() {
        quickAISession?.isAnswerCopied = true
        // 提示显示一会儿就收起；再次复制时重新计时。
        quickAICopiedHintTask?.cancel()
        quickAICopiedHintTask = Task { [weak self] in
            try? await Task.sleep(for: Self.quickAICopiedHintDuration)
            guard !Task.isCancelled else { return }
            self?.quickAISession?.isAnswerCopied = false
        }
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

    /// 用默认 App 在后台打开文件，与启动应用一致。
    @discardableResult
    private func open(_ file: FileDescriptor) -> Task<Void, Never>? {
        guard let openFile else { return nil }
        return Task { [weak self] in
            do {
                try await openFile.execute(file)
            } catch {
                self?.notifyOpenFailure(error)
            }
        }
    }

    /// 在默认浏览器中后台打开网址，与启动应用一致。
    @discardableResult
    private func openExternalURL(_ url: URL) -> Task<Void, Never>? {
        guard let openURL else { return nil }
        return Task { [weak self] in
            do {
                try await openURL.execute(url)
            } catch {
                self?.notifyOpenFailure(error)
            }
        }
    }

    /// 打开在后台进行，失败时面板已经收起，只能经系统通知告知。
    private func notifyOpenFailure(_ error: Error) {
        let notification = LauncherErrorMessage.notification(for: error)
        notifier.notify(title: notification.title, body: notification.body)
    }

    /// 为最后一轮发起请求，带上此前各轮的问答（见 `QuickAISession.history`）。
    private func streamLastQuickAITurn() -> Task<Void, Never>? {
        guard let askQuickAI, let session = quickAISession else { return nil }
        isActionSheetVisible = false
        updatePanelHeight()

        let question = session.lastTurn.question
        let history = session.history
        // 中断（Esc、隐藏面板、返回检索）后到达的增量与错误由 `quickAIRequest` 丢弃。
        return quickAIRequest.start { onDelta in
            try await askQuickAI.execute(question: question, history: history, onDelta: onDelta)
        } onCompletion: { [weak self] error in
            if let error {
                self?.quickAISession?.lastTurn.state = .failed(LauncherErrorMessage.message(for: error))
            } else {
                self?.quickAISession?.lastTurn.state = .finished
            }
        }
    }

    /// 丢弃当前对话（之后不再恢复）；Quick AI 模式本身保持不变。
    private func discardQuickAISession() {
        stopQuickAI()
        quickAIRequest.discard()
        quickAIClosedAt = nil
        guard quickAISession != nil else { return }
        quickAISession = nil
        updatePanelHeight()
    }

    private func refreshSearchResults() {
        isActionSheetVisible = false
        if case .failed = launchState {
            launchState = .idle
        }
        quickQueryResult = quickQueryResolver.resolve(query)
        webURLResult = WebURLResolver.recognize(query)
        schedulePathLookup()
        scheduleFileSearch()
        updateFilteredApps()
        requestListReset()
    }

    private var normalizedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 以 `/` 或 `~` 开头的输入按路径处理：只做路径直达，不做文件搜索，以免列出名称无关的文件。
    private var isPathQuery: Bool {
        normalizedQuery.hasPrefix("/") || normalizedQuery.hasPrefix("~")
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

    /// 路径直达在后台查看文件系统：路径落在无响应的网络卷上时可能阻塞数秒，不能逐字卡住主线程。
    /// 过期的结果按 generation 丢弃，最新的输入总是胜出；查看期间保留上一次的直达行，
    /// 逐字输入一个仍然存在的路径时，直达行不会先消失再出现、带着面板高度来回跳动。
    private func schedulePathLookup() {
        pathLookupTask?.cancel()
        pathLookupTask = nil
        pathLookupGeneration += 1
        let generation = pathLookupGeneration

        guard isPathQuery, let openFile else {
            pathResult = nil
            return
        }
        let path = normalizedQuery
        pathLookupTask = Task { [weak self] in
            let item = await openFile.item(atPath: path)
            guard let self, self.pathLookupGeneration == generation else { return }
            self.pathLookupTask = nil
            guard item != self.pathResult else { return }
            self.pathResult = item
            // 直达行排在最前，其后的结果整体移动：选择回到第一项，展开中的操作菜单随之收起。
            self.isActionSheetVisible = false
            self.selectedIndex = 0
            self.updatePanelHeight()
            self.requestListReset()
        }
    }

    /// 带防抖的文件查询；过期结果按 generation 丢弃，最新的查询总是胜出。查询失败时文件分组留空。
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
              !isPathQuery,
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
