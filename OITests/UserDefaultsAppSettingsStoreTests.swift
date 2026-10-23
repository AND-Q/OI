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

    /// 网页搜索引擎随设置持久化；未知取值（如旧版本或手工改动）回退默认引擎。
    func testWebSearchEngineRoundTripsAndFallsBackForUnknownValue() throws {
        let context = try makeStore()
        defer { context.cleanup() }

        context.store.save(AppSettings(webSearchEngine: .duckDuckGo))
        XCTAssertEqual(
            UserDefaultsAppSettingsStore(defaults: context.defaults).load().webSearchEngine,
            .duckDuckGo
        )

        context.defaults.set("altavista", forKey: "settings.webSearchEngine")
        XCTAssertEqual(context.store.load().webSearchEngine, .bing)
    }

    /// 旧版本的划词翻译与 Quick AI 共用接口：从未保存过翻译接口时沿用 Quick AI 的值，
    /// 保存后两者各自独立，翻译接口留空也不再回退。
    func testTranslationEndpointFallsBackToQuickAIUntilSaved() throws {
        let context = try makeStore()
        defer { context.cleanup() }
        context.defaults.set("https://api.openai.com/v1", forKey: "settings.quickAI.baseURL")
        context.defaults.set("gpt-4o-mini", forKey: "settings.quickAI.model")

        var settings = context.store.load()
        XCTAssertEqual(settings.translationBaseURL, "https://api.openai.com/v1")
        XCTAssertEqual(settings.translationModel, "gpt-4o-mini")

        settings.quickAIModel = "gpt-4o"
        settings.translationBaseURL = ""
        settings.translationModel = ""
        context.store.save(settings)

        let reloaded = UserDefaultsAppSettingsStore(defaults: context.defaults).load()
        XCTAssertEqual(reloaded.quickAIModel, "gpt-4o")
        XCTAssertEqual(reloaded.translationBaseURL, "")
        XCTAssertEqual(reloaded.translationModel, "")
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
        let settings = AppSettings(launcherShortcut: GlobalShortcut(keyCode: 2, modifiers: 1 << 8 | 1 << 12))

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
            GlobalShortcut.defaultLauncher
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
                GlobalShortcut.defaultLauncher,
                "脏数据 \(corrupt) 应回退默认组合"
            )
        }

        // 非负但组合非法：无修饰键的裸键不应被上层注册为全局热键。
        context.defaults.set(49, forKey: "settings.launcherShortcut.keyCode")
        context.defaults.set(0, forKey: "settings.launcherShortcut.modifiers")

        XCTAssertEqual(context.store.load().launcherShortcut, GlobalShortcut.defaultLauncher)

        // 旧版本允许保存的 ⌘C 这类组合会覆盖各应用的同名快捷键，同样回退默认。
        context.defaults.set(8, forKey: "settings.launcherShortcut.keyCode")
        context.defaults.set(1 << 8, forKey: "settings.launcherShortcut.modifiers")

        XCTAssertEqual(context.store.load().launcherShortcut, GlobalShortcut.defaultLauncher)
    }

    // MARK: - 辅助方法

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
