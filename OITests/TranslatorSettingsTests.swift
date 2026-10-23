import AppKit
import AVFoundation
import Foundation
import XCTest

@testable import OI

/// 划词翻译的设置项与协调者对翻译快捷键、用力点按的接线。
@MainActor
final class TranslatorSettingsTests: TranslatorTestCase {
    // MARK: - 设置

    func testUserDefaultsStoreRoundTripsTranslatorSettings() throws {
        let suiteName = "OITests-Translator-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = AppSettings(
            isForceTouchTranslationEnabled: false,
            translatorShortcut: GlobalShortcut(keyCode: 17, modifiers: 1 << 8 | 1 << 11),
            screenTranslatorShortcut: GlobalShortcut(keyCode: 1, modifiers: 1 << 11 | 1 << 12),
            translationTargetLanguage: .japanese,
            translationAlternateLanguage: .french,
            translationBaseURL: "http://localhost:11434/v1",
            translationModel: "qwen2.5",
            translationReasoningEffort: "low"
        )

        UserDefaultsAppSettingsStore(defaults: defaults).save(settings)

        XCTAssertEqual(UserDefaultsAppSettingsStore(defaults: defaults).load(), settings)
    }

    func testUserDefaultsStoreFallsBackForUnknownLanguageAndInvalidShortcut() throws {
        let suiteName = "OITests-Translator-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("xx", forKey: "settings.translator.targetLanguage")
        defaults.set(2, forKey: "settings.translator.shortcut.keyCode")
        defaults.set(0, forKey: "settings.translator.shortcut.modifiers")
        defaults.set(2, forKey: "settings.translator.screenShortcut.keyCode")
        defaults.set(1 << 9, forKey: "settings.translator.screenShortcut.modifiers")

        let settings = UserDefaultsAppSettingsStore(defaults: defaults).load()

        XCTAssertEqual(settings.translationTargetLanguage, .simplifiedChinese)
        XCTAssertEqual(settings.translatorShortcut, .defaultTranslator)
        XCTAssertEqual(settings.screenTranslatorShortcut, .defaultScreenTranslator, "只有 ⇧ 不能用作全局快捷键")
    }

    func testApplyTranslatorShortcutActivatesAndPersists() {
        let settingsStore = MemoryAppSettingsStore()
        let viewModel = makeSettingsViewModel(settingsStore: settingsStore)
        let activator = RecordingActivator()
        viewModel.translatorShortcutActivator = activator.activate
        let shortcut = GlobalShortcut(keyCode: 17, modifiers: 1 << 8 | 1 << 11)

        viewModel.applyTranslatorShortcut(shortcut)

        XCTAssertEqual(activator.attempts, [shortcut])
        XCTAssertEqual(settingsStore.load().translatorShortcut, shortcut)
        XCTAssertNil(viewModel.translatorShortcutNotice)
    }

    func testApplyTranslatorShortcutFailureRollsBack() {
        let viewModel = makeSettingsViewModel()
        let activator = RecordingActivator()
        let rejected = GlobalShortcut(keyCode: 17, modifiers: 1 << 8 | 1 << 12)
        activator.errors[rejected] = "该快捷键已被其他应用占用"
        viewModel.translatorShortcutActivator = activator.activate

        viewModel.applyTranslatorShortcut(rejected)

        XCTAssertEqual(activator.attempts, [rejected, .defaultTranslator])
        XCTAssertEqual(viewModel.settings.translatorShortcut, .defaultTranslator)
        XCTAssertEqual(viewModel.translatorShortcutNotice, .failure("该快捷键已被其他应用占用"))
        XCTAssertNil(viewModel.launcherShortcutNotice, "失败提示只出现在翻译快捷键下")
    }

    func testShortcutsCannotShareTheSameCombination() {
        let viewModel = makeSettingsViewModel()
        let launcherActivator = RecordingActivator()
        let translatorActivator = RecordingActivator()
        viewModel.launcherShortcutActivator = launcherActivator.activate
        viewModel.translatorShortcutActivator = translatorActivator.activate

        let screenActivator = RecordingActivator()
        viewModel.screenTranslatorShortcutActivator = screenActivator.activate

        viewModel.applyTranslatorShortcut(.defaultLauncher)
        viewModel.applyLauncherShortcut(.defaultTranslator)
        viewModel.applyScreenTranslatorShortcut(.defaultTranslator)
        viewModel.applyTranslatorShortcut(.defaultScreenTranslator)

        XCTAssertEqual(translatorActivator.attempts, [])
        XCTAssertEqual(launcherActivator.attempts, [])
        XCTAssertEqual(screenActivator.attempts, [])
        XCTAssertEqual(viewModel.translatorShortcutNotice, .failure("与截图翻译快捷键相同，请换一个组合"))
        XCTAssertEqual(viewModel.launcherShortcutNotice, .failure("与翻译快捷键相同，请换一个组合"))
        XCTAssertEqual(viewModel.screenTranslatorShortcutNotice, .failure("与翻译快捷键相同，请换一个组合"))
        XCTAssertEqual(viewModel.settings.translatorShortcut, .defaultTranslator)
        XCTAssertEqual(viewModel.settings.launcherShortcut, .defaultLauncher)
        XCTAssertEqual(viewModel.settings.screenTranslatorShortcut, .defaultScreenTranslator)
    }

    func testApplyScreenTranslatorShortcutActivatesAndPersists() {
        let settingsStore = MemoryAppSettingsStore()
        let viewModel = makeSettingsViewModel(settingsStore: settingsStore)
        let activator = RecordingActivator()
        viewModel.screenTranslatorShortcutActivator = activator.activate
        let shortcut = GlobalShortcut(keyCode: 1, modifiers: 1 << 11 | 1 << 12)

        viewModel.applyScreenTranslatorShortcut(shortcut)

        XCTAssertEqual(activator.attempts, [shortcut])
        XCTAssertEqual(settingsStore.load().screenTranslatorShortcut, shortcut)
        XCTAssertNil(viewModel.screenTranslatorShortcutNotice)

        viewModel.reportShortcutRegistrationFailure(StubError(message: "该快捷键已被其他应用占用"), for: .screenTranslator)

        XCTAssertEqual(viewModel.screenTranslatorShortcutNotice, .failure("该快捷键已被其他应用占用"))
        XCTAssertNil(viewModel.translatorShortcutNotice)
    }

    /// 两个翻译语言不会相同：选成另一项的语言时两者互换，否则只改这一项。
    func testTranslationLanguagesSwapInsteadOfBecomingTheSame() {
        let settingsStore = MemoryAppSettingsStore()
        let viewModel = makeSettingsViewModel(settingsStore: settingsStore)

        viewModel.setTranslationTargetLanguage(.english)
        XCTAssertEqual(viewModel.settings.translationTargetLanguage, .english)
        XCTAssertEqual(viewModel.settings.translationAlternateLanguage, .simplifiedChinese)

        viewModel.setTranslationAlternateLanguage(.english)
        XCTAssertEqual(viewModel.settings.translationTargetLanguage, .simplifiedChinese)
        XCTAssertEqual(viewModel.settings.translationAlternateLanguage, .english)

        viewModel.setTranslationTargetLanguage(.japanese)
        XCTAssertEqual(viewModel.settings.translationTargetLanguage, .japanese)
        XCTAssertEqual(viewModel.settings.translationAlternateLanguage, .english, "不冲突时只改这一项")
        XCTAssertEqual(settingsStore.load().translationTargetLanguage, .japanese)
        XCTAssertEqual(settingsStore.load().translationAlternateLanguage, .english)
    }

    func testSettingsViewModelRefreshesPermissionsAndForwardsRequests() {
        let environment = MemoryTranslatorEnvironment(isAccessibilityTrusted: false)
        let viewModel = makeSettingsViewModel(environment: environment)
        XCTAssertFalse(viewModel.isAccessibilityTrusted)
        XCTAssertFalse(viewModel.isScreenCaptureTrusted)

        environment.isAccessibilityTrusted = true
        environment.isScreenCaptureTrusted = true
        viewModel.refreshPermissionStatus()
        viewModel.requestAccessibilityAccess()
        viewModel.requestScreenCaptureAccess()
        viewModel.openTrackpadSettings()

        XCTAssertTrue(viewModel.isAccessibilityTrusted)
        XCTAssertTrue(viewModel.isScreenCaptureTrusted)
        XCTAssertEqual(environment.accessibilityRequestCount, 1)
        XCTAssertEqual(environment.screenCaptureRequestCount, 1)
        XCTAssertEqual(environment.trackpadSettingsOpenCount, 1)
    }

    func testReportTranslatorShortcutRegistrationFailureSetsNotice() {
        let viewModel = makeSettingsViewModel()

        viewModel.reportShortcutRegistrationFailure(StubError(message: "该快捷键已被其他应用占用"), for: .translator)

        XCTAssertEqual(viewModel.translatorShortcutNotice, .failure("该快捷键已被其他应用占用"))
        XCTAssertNil(viewModel.launcherShortcutNotice)
    }

    // MARK: - 协调者

    func testCoordinatorRegistersTranslatorShortcutAndForceTouchMonitor() {
        let settingsStore = MemoryAppSettingsStore()
        let launcherService = RecordingShortcutService()
        let translatorService = RecordingShortcutService()
        let screenService = RecordingShortcutService()
        let monitor = RecordingForceTouchMonitor()
        let coordinator = AppCoordinator(
            dependencies: AppDependencies(
                launcherViewModel: makeViewModel(with: [], settingsStore: settingsStore),
                settingsViewModel: makeSettingsViewModel(settingsStore: settingsStore),
                settingsStore: settingsStore,
                iconProvider: StubIconProvider(),
                globalShortcutService: launcherService,
                translator: TranslatorDependencies(
                    makeViewModel: { self.makeTranslatorViewModel(settings: AppSettings()) },
                    shortcutService: translatorService,
                    screenShortcutService: screenService,
                    forceTouchMonitor: monitor
                )
            )
        )
        defer { coordinator.stop() }

        coordinator.start()

        XCTAssertEqual(launcherService.registeredShortcuts, [.defaultLauncher])
        XCTAssertEqual(translatorService.registeredShortcuts, [.defaultTranslator])
        XCTAssertNotNil(translatorService.handler)
        XCTAssertEqual(screenService.registeredShortcuts, [.defaultScreenTranslator])
        XCTAssertNotNil(screenService.handler)
        XCTAssertTrue(monitor.isRunning)

        coordinator.stop()

        XCTAssertNil(translatorService.handler)
        XCTAssertNil(screenService.handler)
        XCTAssertFalse(monitor.isRunning)
    }

    /// 用力点按取词关闭时不启动全局监听；在设置中开启或关闭后随之启停。
    func testCoordinatorStartsForceTouchMonitorOnlyWhenEnabled() {
        let settingsStore = MemoryAppSettingsStore(initial: AppSettings(isForceTouchTranslationEnabled: false))
        let settingsViewModel = makeSettingsViewModel(settingsStore: settingsStore)
        let monitor = RecordingForceTouchMonitor()
        let coordinator = AppCoordinator(
            dependencies: AppDependencies(
                launcherViewModel: makeViewModel(with: [], settingsStore: settingsStore),
                settingsViewModel: settingsViewModel,
                settingsStore: settingsStore,
                iconProvider: StubIconProvider(),
                globalShortcutService: RecordingShortcutService(),
                translator: TranslatorDependencies(
                    makeViewModel: { self.makeTranslatorViewModel(settings: AppSettings()) },
                    shortcutService: RecordingShortcutService(),
                    screenShortcutService: RecordingShortcutService(),
                    forceTouchMonitor: monitor
                )
            )
        )
        defer { coordinator.stop() }

        coordinator.start()
        XCTAssertFalse(monitor.isRunning)

        settingsViewModel.settings.isForceTouchTranslationEnabled = true
        XCTAssertTrue(monitor.isRunning)

        settingsViewModel.settings.isForceTouchTranslationEnabled = false
        XCTAssertFalse(monitor.isRunning)
    }
}
