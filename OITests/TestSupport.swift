import Foundation
import XCTest

@testable import OI

@MainActor
extension XCTestCase {
    func makeViewModel(
        with descriptors: [AppDescriptor],
        aliases: [String: [String]] = [:],
        usageStore: any AppUsageStoring = MemoryAppUsageStore(),
        urlOpener: OpenURL? = nil,
        now: @escaping () -> Date = { Date() }
    ) -> LauncherViewModel {
        LauncherViewModel(
            discoverApplications: DiscoverApplications(
                catalog: StubAppCatalog(descriptors: descriptors)
            ),
            launchApplication: LaunchApplication(
                launcher: StubApplicationLauncher()
            ),
            openURL: urlOpener,
            usageStore: usageStore,
            aliases: aliases,
            now: now
        )
    }

    func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OITests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @discardableResult
    func makeApplicationBundle(
        directoryName: String,
        displayName: String,
        bundleIdentifier: String? = nil,
        in root: URL
    ) throws -> URL {
        let bundleURL = root.appendingPathComponent(directoryName, isDirectory: true)
        let contentsURL = bundleURL.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contentsURL, withIntermediateDirectories: true)

        var info: [String: Any] = [
            "CFBundleDisplayName": displayName,
            "CFBundleName": displayName,
            "CFBundlePackageType": "APPL"
        ]
        if let bundleIdentifier {
            info["CFBundleIdentifier"] = bundleIdentifier
        }
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try data.write(to: contentsURL.appendingPathComponent("Info.plist"))
        return bundleURL
    }
}

struct StubAppCatalog: AppCatalog {
    let descriptors: [AppDescriptor]

    func scan() async throws -> [AppDescriptor] {
        try Task.checkCancellation()
        return descriptors
    }
}

struct CountingAppCatalog: AppCatalog {
    let descriptors: [AppDescriptor]
    let counter: ScanCounter

    func scan() async throws -> [AppDescriptor] {
        counter.increment()
        return descriptors
    }
}

final class SequencedAppCatalog: AppCatalog, @unchecked Sendable {
    private let results: [[AppDescriptor]]
    private let lock = NSLock()
    private var scans = 0

    init(results: [[AppDescriptor]]) {
        self.results = results
    }

    func scan() async throws -> [AppDescriptor] {
        let index = lock.withLock {
            let index = scans
            scans += 1
            return index
        }
        try? await Task.sleep(nanoseconds: 200_000_000)
        guard index < results.count else { return results.last ?? [] }
        return results[index]
    }
}

final class ScanCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var countValue = 0

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return countValue
    }

    func increment() {
        lock.lock()
        countValue += 1
        lock.unlock()
    }
}

final class DateHolder {
    var date = Date(timeIntervalSinceReferenceDate: 0)
}

struct ThrowingAppCatalog: AppCatalog {
    enum CatalogError: LocalizedError {
        case unavailable

        var errorDescription: String? { "目录不可用" }
    }

    func scan() async throws -> [AppDescriptor] {
        throw CatalogError.unavailable
    }
}

@MainActor
final class StubApplicationLauncher: ApplicationLaunching {
    private(set) var launchedApplications: [AppDescriptor] = []

    func launch(_ application: AppDescriptor) async throws {
        launchedApplications.append(application)
    }
}

@MainActor
final class StubURLOpener: URLOpening {
    private(set) var openedURLs: [URL] = []

    func open(_ url: URL) async throws {
        openedURLs.append(url)
    }
}

@MainActor
final class ThrowingURLOpener: URLOpening {
    enum OpenError: LocalizedError {
        case failed

        var errorDescription: String? { "无法打开浏览器" }
    }

    func open(_ url: URL) async throws {
        throw OpenError.failed
    }
}

@MainActor
final class ThrowingApplicationLauncher: ApplicationLaunching {
    enum LaunchError: LocalizedError {
        case failed

        var errorDescription: String? { "启动失败" }
    }

    func launch(_ application: AppDescriptor) async throws {
        throw LaunchError.failed
    }
}
