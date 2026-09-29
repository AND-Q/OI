import Foundation
import XCTest

@testable import OI

@MainActor
final class UserDefaultsAppSettingsStoreTests: XCTestCase {
    func testLoadReturnsDefaultsWhenNothingPersisted() throws {
        let context = try makeStore()
        defer { context.cleanup() }

        XCTAssertEqual(context.store.load(), AppSettings())
    }

    func testSaveThenLoadRoundTripsAllValues() throws {
        let context = try makeStore()
        defer { context.cleanup() }
        let settings = AppSettings(
            isSilentLaunchEnabled: false,
            isFileSearchEnabled: false,
            isUsageRankingEnabled: false
        )

        context.store.save(settings)

        XCTAssertEqual(context.store.load(), settings)
    }

    func testSavePersistsAcrossStoreInstances() throws {
        let context = try makeStore()
        defer { context.cleanup() }
        let settings = AppSettings(isSilentLaunchEnabled: false)

        context.store.save(settings)

        XCTAssertEqual(
            UserDefaultsAppSettingsStore(defaults: context.defaults).load(),
            settings
        )
    }

    // MARK: - Helpers

    /// 每个测试使用独立的 defaults suite，结束后删除域避免污染宿主偏好设置。
    private func makeStore() throws -> (
        store: UserDefaultsAppSettingsStore,
        defaults: UserDefaults,
        cleanup: () -> Void
    ) {
        let suiteName = "OITests.settings.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let store = UserDefaultsAppSettingsStore(defaults: defaults)
        return (store, defaults, { defaults.removePersistentDomain(forName: suiteName) })
    }
}
