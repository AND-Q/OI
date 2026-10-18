import Foundation
import XCTest

@testable import OI

@MainActor
final class SettingsViewModelTests: XCTestCase {
    func testInitLoadsPersistedSettingsAndLoginItemStatus() {
        let persisted = AppSettings(
            isSilentLaunchEnabled: false,
            isFileSearchEnabled: false,
            isUsageRankingEnabled: false
        )
        let viewModel = makeViewModel(
            settingsStore: MemoryAppSettingsStore(initial: persisted),
            loginItemController: StubLoginItemController(initialStatus: .enabled)
        )

        XCTAssertEqual(viewModel.settings, persisted)
        XCTAssertTrue(viewModel.isLaunchAtLoginEnabled)
        XCTAssertNil(viewModel.launchAtLoginNotice)
    }

    func testSettingsChangesPersistToStore() {
        let settingsStore = MemoryAppSettingsStore()
        let viewModel = makeViewModel(settingsStore: settingsStore)

        viewModel.settings.isSilentLaunchEnabled = false
        viewModel.settings.isFileSearchEnabled = false
        viewModel.settings.isUsageRankingEnabled = false

        XCTAssertEqual(
            settingsStore.load(),
            AppSettings(
                isSilentLaunchEnabled: false,
                isFileSearchEnabled: false,
                isUsageRankingEnabled: false
            )
        )
    }

    func testSetLaunchAtLoginRegistersAndUnregistersLoginItem() {
        let loginItems = StubLoginItemController()
        let viewModel = makeViewModel(loginItemController: loginItems)

        viewModel.setLaunchAtLogin(true)

        XCTAssertEqual(loginItems.registerCalls, 1)
        XCTAssertTrue(viewModel.isLaunchAtLoginEnabled)
        XCTAssertNil(viewModel.launchAtLoginNotice)

        viewModel.setLaunchAtLogin(false)

        XCTAssertEqual(loginItems.unregisterCalls, 1)
        XCTAssertFalse(viewModel.isLaunchAtLoginEnabled)
        XCTAssertNil(viewModel.launchAtLoginNotice)
    }

    func testSetLaunchAtLoginShowsApprovalPendingNotice() {
        let viewModel = makeViewModel(
            loginItemController: StubLoginItemController(postRegisterStatus: .requiresApproval)
        )

        viewModel.setLaunchAtLogin(true)

        XCTAssertTrue(viewModel.isLaunchAtLoginEnabled)
        XCTAssertEqual(viewModel.launchAtLoginNotice, .approvalPending)
    }

    func testSetLaunchAtLoginFailureRevertsToSystemStatus() {
        let loginItems = StubLoginItemController()
        loginItems.registerError = StubLoginItemController.StubError.registrationFailed
        let viewModel = makeViewModel(loginItemController: loginItems)

        viewModel.setLaunchAtLogin(true)

        XCTAssertFalse(viewModel.isLaunchAtLoginEnabled)
        XCTAssertEqual(viewModel.launchAtLoginNotice, .failure("无法注册登录项"))

        // 系统状态仍是未注册，重复移除被幂等跳过。
        viewModel.setLaunchAtLogin(false)
        XCTAssertEqual(loginItems.unregisterCalls, 0)
    }

    func testSetLaunchAtLoginUnregisterFailureKeepsEnabled() {
        let loginItems = StubLoginItemController(initialStatus: .enabled)
        loginItems.unregisterError = StubLoginItemController.StubError.removalFailed
        let viewModel = makeViewModel(loginItemController: loginItems)

        viewModel.setLaunchAtLogin(false)

        XCTAssertTrue(viewModel.isLaunchAtLoginEnabled)
        XCTAssertEqual(viewModel.launchAtLoginNotice, .failure("无法移除登录项"))
    }

    func testSetLaunchAtLoginSkipsRedundantSystemCalls() {
        let loginItems = StubLoginItemController(initialStatus: .enabled)
        let viewModel = makeViewModel(loginItemController: loginItems)

        viewModel.setLaunchAtLogin(true)
        XCTAssertEqual(loginItems.registerCalls, 0)

        viewModel.setLaunchAtLogin(false)
        viewModel.setLaunchAtLogin(false)
        XCTAssertEqual(loginItems.unregisterCalls, 1)
    }

    func testRefreshLaunchAtLoginStatusSyncsWithSystem() {
        let loginItems = StubLoginItemController()
        let viewModel = makeViewModel(loginItemController: loginItems)
        XCTAssertFalse(viewModel.isLaunchAtLoginEnabled)

        loginItems.status = .enabled
        viewModel.refreshLaunchAtLoginStatus()

        XCTAssertTrue(viewModel.isLaunchAtLoginEnabled)
    }

    func testInitShowsApprovalPendingWhenSystemRequiresApproval() {
        let viewModel = makeViewModel(
            loginItemController: StubLoginItemController(initialStatus: .requiresApproval)
        )

        XCTAssertTrue(viewModel.isLaunchAtLoginEnabled)
        XCTAssertEqual(viewModel.launchAtLoginNotice, .approvalPending)
    }

    func testRefreshLaunchAtLoginStatusShowsApprovalPending() {
        let loginItems = StubLoginItemController()
        let viewModel = makeViewModel(loginItemController: loginItems)

        loginItems.status = .requiresApproval
        viewModel.refreshLaunchAtLoginStatus()

        XCTAssertTrue(viewModel.isLaunchAtLoginEnabled)
        XCTAssertEqual(viewModel.launchAtLoginNotice, .approvalPending)
    }

    func testRefreshLaunchAtLoginStatusClearsApprovalPendingAfterApproval() {
        let loginItems = StubLoginItemController(postRegisterStatus: .requiresApproval)
        let viewModel = makeViewModel(loginItemController: loginItems)
        viewModel.setLaunchAtLogin(true)
        XCTAssertEqual(viewModel.launchAtLoginNotice, .approvalPending)

        // 用户在系统设置中批准后，等待批准的提示应随刷新清除。
        loginItems.status = .enabled
        viewModel.refreshLaunchAtLoginStatus()

        XCTAssertTrue(viewModel.isLaunchAtLoginEnabled)
        XCTAssertNil(viewModel.launchAtLoginNotice)
    }

    func testRefreshLaunchAtLoginStatusKeepsFailureNotice() {
        let loginItems = StubLoginItemController(initialStatus: .enabled)
        loginItems.unregisterError = StubLoginItemController.StubError.removalFailed
        let viewModel = makeViewModel(loginItemController: loginItems)
        viewModel.setLaunchAtLogin(false)
        XCTAssertEqual(viewModel.launchAtLoginNotice, .failure("无法移除登录项"))

        viewModel.refreshLaunchAtLoginStatus()

        XCTAssertEqual(viewModel.launchAtLoginNotice, .failure("无法移除登录项"))
    }

    // MARK: - 呼出快捷键

    func testApplyLauncherShortcutActivatesAndPersists() {
        let settingsStore = MemoryAppSettingsStore()
        let viewModel = makeViewModel(settingsStore: settingsStore)
        let activator = StubShortcutActivator()
        viewModel.launcherShortcutActivator = activator.activate
        let shortcut = LauncherShortcut(keyCode: 2, modifiers: 1 << 8 | 1 << 12)

        viewModel.applyLauncherShortcut(shortcut)

        XCTAssertEqual(activator.attempts, [shortcut])
        XCTAssertEqual(viewModel.settings.launcherShortcut, shortcut)
        XCTAssertEqual(settingsStore.load().launcherShortcut, shortcut)
        XCTAssertNil(viewModel.launcherShortcutNotice)
    }

    func testApplyLauncherShortcutFailureKeepsPreviousAndRollsBackActivation() {
        let settingsStore = MemoryAppSettingsStore()
        let viewModel = makeViewModel(settingsStore: settingsStore)
        let activator = StubShortcutActivator()
        activator.errors[LauncherShortcut(keyCode: 2, modifiers: 1 << 8 | 1 << 11)] = "该快捷键已被其他应用占用"
        viewModel.launcherShortcutActivator = activator.activate
        let rejected = LauncherShortcut(keyCode: 2, modifiers: 1 << 8 | 1 << 11)

        viewModel.applyLauncherShortcut(rejected)

        // 注册失败后按原快捷键重新激活，保证呼出热键始终可用。
        XCTAssertEqual(activator.attempts, [rejected, LauncherShortcut.standard])
        XCTAssertEqual(viewModel.settings.launcherShortcut, LauncherShortcut.standard)
        XCTAssertEqual(settingsStore.load().launcherShortcut, LauncherShortcut.standard)
        XCTAssertEqual(viewModel.launcherShortcutNotice, .failure("该快捷键已被其他应用占用"))
    }

    /// 回滚注册也失败（原组合在间隙被抢占）时，用户没有任何呼出热键，
    /// 提示必须表达这个更严重的后果并给出恢复手段，而非只描述新组合被占用。
    func testRollbackFailureSurfacesNoActiveShortcutNotice() {
        let settingsStore = MemoryAppSettingsStore()
        let viewModel = makeViewModel(settingsStore: settingsStore)
        let activator = StubShortcutActivator()
        activator.errors[LauncherShortcut(keyCode: 2, modifiers: 1 << 8 | 1 << 11)] = "新组合被占用"
        activator.errors[LauncherShortcut.standard] = "原组合被抢占"
        viewModel.launcherShortcutActivator = activator.activate

        viewModel.applyLauncherShortcut(LauncherShortcut(keyCode: 2, modifiers: 1 << 8 | 1 << 11))

        XCTAssertEqual(activator.attempts, [LauncherShortcut(keyCode: 2, modifiers: 1 << 8 | 1 << 11), .standard])
        XCTAssertEqual(viewModel.settings.launcherShortcut, LauncherShortcut.standard)
        XCTAssertEqual(settingsStore.load().launcherShortcut, LauncherShortcut.standard)
        XCTAssertEqual(
            viewModel.launcherShortcutNotice,
            .failure("原快捷键重新注册也失败，当前没有可用的呼出快捷键（新组合原因：新组合被占用）。请重新录制组合或重启 OI")
        )
    }

    func testApplyLauncherShortcutClearsFailureNoticeOnSuccess() {
        let viewModel = makeViewModel()
        let activator = StubShortcutActivator()
        activator.errors[LauncherShortcut(keyCode: 2, modifiers: 1 << 8 | 1 << 11)] = "占用"
        viewModel.launcherShortcutActivator = activator.activate
        viewModel.applyLauncherShortcut(LauncherShortcut(keyCode: 2, modifiers: 1 << 8 | 1 << 11))

        viewModel.applyLauncherShortcut(LauncherShortcut(keyCode: 3, modifiers: 1 << 11))

        XCTAssertNil(viewModel.launcherShortcutNotice)
        XCTAssertEqual(viewModel.settings.launcherShortcut, LauncherShortcut(keyCode: 3, modifiers: 1 << 11))
    }

    func testApplyInvalidLauncherShortcutIsRejectedWithoutActivation() {
        let settingsStore = MemoryAppSettingsStore()
        let viewModel = makeViewModel(settingsStore: settingsStore)
        let activator = StubShortcutActivator()
        viewModel.launcherShortcutActivator = activator.activate

        viewModel.applyLauncherShortcut(LauncherShortcut(keyCode: 0, modifiers: 0))

        XCTAssertEqual(activator.attempts, [])
        XCTAssertEqual(viewModel.settings.launcherShortcut, LauncherShortcut.standard)
        XCTAssertEqual(settingsStore.load().launcherShortcut, LauncherShortcut.standard)
        XCTAssertEqual(viewModel.launcherShortcutNotice, .failure("快捷键需包含 ⌘、⌥ 或 ⌃ 修饰键"))
    }

    /// 只用 ⌘ 配字母等键会覆盖各应用的同名快捷键（如 ⌘Q），不尝试注册并给出原因。
    func testApplyCommandOnlyLetterShortcutIsRejectedWithoutActivation() {
        let settingsStore = MemoryAppSettingsStore()
        let viewModel = makeViewModel(settingsStore: settingsStore)
        let activator = StubShortcutActivator()
        viewModel.launcherShortcutActivator = activator.activate

        viewModel.applyLauncherShortcut(LauncherShortcut(keyCode: 12, modifiers: 1 << 8)) // ⌘Q

        XCTAssertEqual(activator.attempts, [])
        XCTAssertEqual(settingsStore.load().launcherShortcut, LauncherShortcut.standard)
        XCTAssertEqual(
            viewModel.launcherShortcutNotice,
            .failure("只用 ⌘ 会覆盖各应用的同名快捷键，请加上 ⌥ 或 ⌃")
        )
    }

    func testApplySameLauncherShortcutSkipsActivation() {
        let viewModel = makeViewModel()
        let activator = StubShortcutActivator()
        viewModel.launcherShortcutActivator = activator.activate

        viewModel.applyLauncherShortcut(.standard)

        XCTAssertEqual(activator.attempts, [])
        XCTAssertNil(viewModel.launcherShortcutNotice)
    }

    /// 冲突失败后重申当前快捷键：重新激活（自愈回滚失败的场景）并清除失败提示，
    /// 而不是因「与当前值相同」被跳过导致提示永久残留。
    func testReapplyingCurrentShortcutAfterFailureReactivatesAndClearsNotice() {
        let viewModel = makeViewModel()
        let activator = StubShortcutActivator()
        activator.errors[LauncherShortcut(keyCode: 2, modifiers: 1 << 8 | 1 << 11)] = "该快捷键已被其他应用占用"
        viewModel.launcherShortcutActivator = activator.activate
        viewModel.applyLauncherShortcut(LauncherShortcut(keyCode: 2, modifiers: 1 << 8 | 1 << 11))
        XCTAssertEqual(viewModel.launcherShortcutNotice, .failure("该快捷键已被其他应用占用"))

        viewModel.applyLauncherShortcut(.standard)

        XCTAssertEqual(
            activator.attempts,
            [LauncherShortcut(keyCode: 2, modifiers: 1 << 8 | 1 << 11), .standard, .standard]
        )
        XCTAssertNil(viewModel.launcherShortcutNotice)
        XCTAssertEqual(viewModel.settings.launcherShortcut, .standard)
    }

    func testApplyLauncherShortcutWithoutActivatorIsNoOp() {
        let settingsStore = MemoryAppSettingsStore()
        let viewModel = makeViewModel(settingsStore: settingsStore)

        viewModel.applyLauncherShortcut(LauncherShortcut(keyCode: 2, modifiers: 1 << 8 | 1 << 11))

        XCTAssertEqual(viewModel.settings.launcherShortcut, LauncherShortcut.standard)
        XCTAssertEqual(settingsStore.load().launcherShortcut, LauncherShortcut.standard)
        XCTAssertNil(viewModel.launcherShortcutNotice)
    }

    /// 启动期注册失败由协调者经此入口同步到设置面板，用户能直接看到原因。
    func testReportShortcutRegistrationFailureSetsNotice() {
        let viewModel = makeViewModel()

        viewModel.reportShortcutRegistrationFailure(
            StubShortcutError(message: "该快捷键已被其他应用占用，请换一个组合")
        )

        XCTAssertEqual(
            viewModel.launcherShortcutNotice,
            .failure("该快捷键已被其他应用占用，请换一个组合")
        )
        // 设置值本身不变，恢复默认按钮因提示存在而可点击重试。
        XCTAssertEqual(viewModel.settings.launcherShortcut, LauncherShortcut.standard)
    }

    /// 文件搜索从关闭切到开启时请求一次目录授权；其他设置变化或关闭时不请求。
    func testEnablingFileSearchRequestsFolderAccess() {
        let settingsStore = MemoryAppSettingsStore(initial: AppSettings(isFileSearchEnabled: false))
        let viewModel = makeViewModel(settingsStore: settingsStore)
        var requestCount = 0
        viewModel.fileSearchAccessRequester = { requestCount += 1 }

        viewModel.settings.isUsageRankingEnabled = false
        XCTAssertEqual(requestCount, 0)

        viewModel.settings.isFileSearchEnabled = true
        XCTAssertEqual(requestCount, 1)

        viewModel.settings.isSilentLaunchEnabled = false
        viewModel.settings.isFileSearchEnabled = false
        XCTAssertEqual(requestCount, 1)
    }

    /// 用力点按取词开关变化时通知启停监听；其他设置变化不通知。
    func testToggleForceTouchTranslationActivatesMonitoring() {
        let viewModel = makeViewModel()
        var activations: [Bool] = []
        viewModel.forceTouchTranslationActivator = { activations.append($0) }

        viewModel.settings.isFileSearchEnabled = false
        XCTAssertEqual(activations, [])

        viewModel.settings.isForceTouchTranslationEnabled = false
        viewModel.settings.isForceTouchTranslationEnabled = true
        XCTAssertEqual(activations, [false, true])
    }

    func testQuickAIBaseURLPlaintextWarningFollowsSettings() {
        let viewModel = makeViewModel()
        XCTAssertFalse(viewModel.isQuickAIBaseURLPlaintext)

        viewModel.settings.quickAIBaseURL = "http://203.0.113.10:11434/v1"
        XCTAssertTrue(viewModel.isQuickAIBaseURLPlaintext)

        viewModel.settings.quickAIBaseURL = "https://203.0.113.10/v1"
        XCTAssertFalse(viewModel.isQuickAIBaseURLPlaintext)
    }

    func testTranslationBaseURLPlaintextWarningIsIndependent() {
        let viewModel = makeViewModel()

        viewModel.settings.translationBaseURL = "http://203.0.113.10:11434/v1"
        XCTAssertTrue(viewModel.isTranslationBaseURLPlaintext)
        XCTAssertFalse(viewModel.isQuickAIBaseURLPlaintext)

        viewModel.settings.translationBaseURL = "http://localhost:11434/v1"
        XCTAssertFalse(viewModel.isTranslationBaseURLPlaintext)
    }

    // MARK: - 侧边栏分类与搜索

    func testEmptySearchShowsAllCategoriesInSidebarOrder() {
        XCTAssertEqual(SettingsCategory.filtered(by: ""), SettingsCategory.allCases)
        XCTAssertEqual(SettingsCategory.filtered(by: "   "), SettingsCategory.allCases, "只有空白时视同未输入")
    }

    func testSearchMatchesCategoryTitleAndItemNamesCaseInsensitively() {
        XCTAssertEqual(SettingsCategory.filtered(by: "划词"), [.translator])
        XCTAssertEqual(SettingsCategory.filtered(by: "quick ai"), [.quickAI], "分类名不区分大小写")
        XCTAssertEqual(SettingsCategory.filtered(by: "静默"), [.general], "按设置项名称找到所在分类")
        XCTAssertEqual(SettingsCategory.filtered(by: "屏幕录制"), [.environment])
        XCTAssertEqual(
            SettingsCategory.filtered(by: "api key"),
            [.quickAI, .translator],
            "同名设置项出现在多个分类时都列出，保持侧边栏顺序"
        )
        XCTAssertEqual(SettingsCategory.filtered(by: "快捷键"), [.general, .translator])
    }

    func testSearchWithoutMatchReturnsNoCategory() {
        XCTAssertTrue(SettingsCategory.filtered(by: "不存在的设置").isEmpty)
    }

    // MARK: - Helpers

    private func makeViewModel(
        settingsStore: any AppSettingsStoring = MemoryAppSettingsStore(),
        loginItemController: any LoginItemControlling = StubLoginItemController()
    ) -> SettingsViewModel {
        SettingsViewModel(
            settingsStore: settingsStore,
            loginItemController: loginItemController
        )
    }
}

@MainActor
private final class StubShortcutActivator {
    /// 按调用顺序记录尝试激活的组合。
    private(set) var attempts: [LauncherShortcut] = []
    /// 按组合注入的失败原因；未注入的组合视为激活成功。
    var errors: [LauncherShortcut: String] = [:]

    func activate(_ shortcut: LauncherShortcut) throws {
        attempts.append(shortcut)
        if let error = errors[shortcut] {
            throw StubShortcutError(message: error)
        }
    }
}

private struct StubShortcutError: LocalizedError {
    let message: String

    var errorDescription: String? { message }
}

@MainActor
private final class StubLoginItemController: LoginItemControlling {
    enum StubError: LocalizedError {
        case registrationFailed
        case removalFailed

        var errorDescription: String? {
            switch self {
            case .registrationFailed: "无法注册登录项"
            case .removalFailed: "无法移除登录项"
            }
        }
    }

    var status: LoginItemStatus
    var registerError: Error?
    var unregisterError: Error?
    private let postRegisterStatus: LoginItemStatus
    private(set) var registerCalls = 0
    private(set) var unregisterCalls = 0

    init(
        initialStatus: LoginItemStatus = .notRegistered,
        postRegisterStatus: LoginItemStatus = .enabled
    ) {
        self.status = initialStatus
        self.postRegisterStatus = postRegisterStatus
    }

    func register() throws {
        registerCalls += 1
        if let registerError { throw registerError }
        status = postRegisterStatus
    }

    func unregister() throws {
        unregisterCalls += 1
        if let unregisterError { throw unregisterError }
        status = .notRegistered
    }
}
