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
