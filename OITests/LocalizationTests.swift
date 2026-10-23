import Foundation
import XCTest

@testable import OI

/// 英文界面：本地化资源已打包、界面语言的读写、设置面板的重新打开提示，以及随系统语言选定的默认翻译语言。
@MainActor
final class LocalizationTests: XCTestCase {
    // MARK: - 本地化资源

    /// 字符串目录编译进 App：英文界面取英文，简体中文界面取原文。
    func testEnglishAndChineseStringsAreBundled() throws {
        let english = try localizationBundle("en")
        XCTAssertEqual(english.localizedString(forKey: "聚焦搜索", value: nil, table: nil), "Spotlight Search")
        XCTAssertEqual(english.localizedString(forKey: "无法启动 %@：%@", value: nil, table: nil), "Couldn’t launch %@: %@")
        XCTAssertEqual(english.localizedString(forKey: "划词翻译", value: nil, table: nil), "Translator")

        let chinese = try localizationBundle("zh-Hans")
        XCTAssertEqual(chinese.localizedString(forKey: "聚焦搜索", value: nil, table: nil), "聚焦搜索")
    }

    /// 文件夹授权提示（Info.plist 中的说明）同样有英文。
    func testFolderAccessDescriptionsAreLocalized() throws {
        let english = try localizationBundle("en")
        XCTAssertEqual(
            english.localizedString(forKey: "NSDesktopFolderUsageDescription", value: nil, table: "InfoPlist"),
            "OI needs access to your Desktop to include the files and folders on it in search results."
        )
    }

    // MARK: - 界面语言

    /// 界面语言写在本应用自己的 `AppleLanguages` 偏好中；跟随系统即删除这一偏好。
    func testLanguageControllerWritesAppleLanguagesOfItsOwnDomain() throws {
        let suiteName = "OITests-AppLanguage-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let controller = UserDefaultsAppLanguageController(defaults: defaults, domainName: suiteName)
        XCTAssertEqual(controller.language, .system)

        controller.setLanguage(.english)
        XCTAssertEqual(defaults.persistentDomain(forName: suiteName)?["AppleLanguages"] as? [String], ["en"])
        XCTAssertEqual(controller.language, .english)

        controller.setLanguage(.simplifiedChinese)
        XCTAssertEqual(controller.language, .simplifiedChinese)

        controller.setLanguage(.system)
        XCTAssertNil(defaults.persistentDomain(forName: suiteName)?["AppleLanguages"])
        XCTAssertEqual(controller.language, .system)
    }

    /// 在系统设置中为 OI 指定的语言（带地区）同样识别；OI 没有的语言按跟随系统处理。
    func testLanguageControllerReadsLanguagesSetInSystemSettings() throws {
        let suiteName = "OITests-AppLanguage-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let controller = UserDefaultsAppLanguageController(defaults: defaults, domainName: suiteName)

        defaults.set(["zh-Hans-CN"], forKey: "AppleLanguages")
        XCTAssertEqual(controller.language, .simplifiedChinese)
        defaults.set(["en-GB"], forKey: "AppleLanguages")
        XCTAssertEqual(controller.language, .english)
        defaults.set(["fr"], forKey: "AppleLanguages")
        XCTAssertEqual(controller.language, .system)
    }

    /// 改了界面语言即提示重新打开，改回启动时的语言不再提示；「立即重新打开」交给协调者处理。
    func testChangingLanguageAsksToRelaunchUntilChangedBack() {
        let controller = MemoryAppLanguageController(language: .system)
        let viewModel = SettingsViewModel(
            settingsStore: MemoryAppSettingsStore(),
            loginItemController: StubLoginItemController(),
            appLanguageController: controller
        )
        var relaunchCount = 0
        viewModel.relaunchHandler = { relaunchCount += 1 }
        XCTAssertEqual(viewModel.appLanguage, .system)
        XCTAssertFalse(viewModel.isRelaunchNeededForAppLanguage)

        viewModel.setAppLanguage(.english)
        XCTAssertEqual(controller.language, .english)
        XCTAssertEqual(viewModel.appLanguage, .english)
        XCTAssertTrue(viewModel.isRelaunchNeededForAppLanguage)

        viewModel.relaunch()
        XCTAssertEqual(relaunchCount, 1)

        viewModel.setAppLanguage(.system)
        XCTAssertEqual(controller.language, .system)
        XCTAssertFalse(viewModel.isRelaunchNeededForAppLanguage)
    }

    // MARK: - 默认翻译语言

    /// 外文译为首选语言、首选语言译为英语；英文系统改为英文译简体中文，中文按书写系统区分简繁，不支持的语言按英语处理。
    func testDefaultTranslationLanguagesFollowPreferredLanguage() {
        func pair(_ preferredLanguages: [String]) -> [TranslationLanguage] {
            let languages = TranslationLanguage.defaultPair(preferredLanguages: preferredLanguages)
            return [languages.target, languages.alternate]
        }

        XCTAssertEqual(pair(["zh-Hans-CN", "en-US"]), [.simplifiedChinese, .english])
        XCTAssertEqual(pair(["zh-Hant-TW"]), [.traditionalChinese, .english])
        XCTAssertEqual(pair(["zh-HK"]), [.traditionalChinese, .english])
        XCTAssertEqual(pair(["en-US", "zh-Hans-CN"]), [.english, .simplifiedChinese])
        XCTAssertEqual(pair(["ja-JP"]), [.japanese, .english])
        XCTAssertEqual(pair(["nl-NL"]), [.english, .simplifiedChinese])
        XCTAssertEqual(pair([]), [.english, .simplifiedChinese])
    }

    /// 只有从没保存过翻译语言时才按首选语言选定；保存过的设置不随系统语言变化。
    func testSavedTranslationLanguagesWinOverPreferredLanguage() throws {
        let suiteName = "OITests-TranslationDefaults-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let englishStore = UserDefaultsAppSettingsStore(defaults: defaults, preferredLanguages: ["en-US"])

        XCTAssertEqual(englishStore.load().translationTargetLanguage, .english)
        XCTAssertEqual(englishStore.load().translationAlternateLanguage, .simplifiedChinese)

        var settings = englishStore.load()
        settings.translationTargetLanguage = .french
        settings.translationAlternateLanguage = .german
        englishStore.save(settings)

        let chineseStore = UserDefaultsAppSettingsStore(defaults: defaults, preferredLanguages: ["zh-Hans-CN"])
        XCTAssertEqual(chineseStore.load().translationTargetLanguage, .french)
        XCTAssertEqual(chineseStore.load().translationAlternateLanguage, .german)
    }

    // MARK: - 辅助方法

    private func localizationBundle(_ language: String) throws -> Bundle {
        let path = try XCTUnwrap(Bundle.main.path(forResource: language, ofType: "lproj"), "缺少 \(language).lproj")
        return try XCTUnwrap(Bundle(path: path))
    }
}
