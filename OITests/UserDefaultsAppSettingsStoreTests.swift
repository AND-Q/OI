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

    func testShortcutRoundTripsAcrossStoreInstances() throws {
        let context = try makeStore()
        defer { context.cleanup() }
        let settings = AppSettings(launcherShortcut: LauncherShortcut(keyCode: 2, modifiers: 1 << 8 | 1 << 12))

        context.store.save(settings)

        XCTAssertEqual(
            UserDefaultsAppSettingsStore(defaults: context.defaults).load().launcherShortcut,
            settings.launcherShortcut
        )
    }

    /// 快捷键的两个键视为整体：只有 keyCode 落盘时按未配置处理，回退默认组合。
    func testPartiallyPersistedShortcutFallsBackToDefault() throws {
        let context = try makeStore()
        defer { context.cleanup() }
        context.defaults.set(2, forKey: "settings.launcherShortcut.keyCode")

        XCTAssertEqual(
            context.store.load().launcherShortcut,
            LauncherShortcut.standard
        )
    }

    /// 外部写入的脏数据（负数、越界、无修饰键组合）不崩溃且回退默认，
    /// 不会注册出拦截正常输入的全局热键。
    func testCorruptShortcutValuesFallBackToDefault() throws {
        let context = try makeStore()
        defer { context.cleanup() }

        // 负数与越界值此前会因 UInt32 强转触发运行时致命错误。
        let corruptValues: [(keyCode: Int, modifiers: Int)] = [
            (-1, 1 << 11),
            (49, -5),
            (49, Int(UInt32.max) + 1),
        ]
        for corrupt in corruptValues {
            context.defaults.set(corrupt.keyCode, forKey: "settings.launcherShortcut.keyCode")
            context.defaults.set(corrupt.modifiers, forKey: "settings.launcherShortcut.modifiers")

            XCTAssertEqual(
                context.store.load().launcherShortcut,
                LauncherShortcut.standard,
                "脏数据 \(corrupt) 应回退默认组合"
            )
        }

        // 非负但组合非法：无修饰键的裸键不应被上层注册为全局热键。
        context.defaults.set(49, forKey: "settings.launcherShortcut.keyCode")
        context.defaults.set(0, forKey: "settings.launcherShortcut.modifiers")

        XCTAssertEqual(context.store.load().launcherShortcut, LauncherShortcut.standard)
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
