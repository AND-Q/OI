import Foundation
import XCTest

@testable import OI

@MainActor
final class LauncherModelTests: XCTestCase {
    func testAppDescriptorNormalizesURLAndUsesItAsIdentity() {
        let rawURL = URL(fileURLWithPath: "/tmp/OITests/../OITests/Demo.app")
        let descriptor = AppDescriptor(name: "Demo", url: rawURL)

        XCTAssertEqual(descriptor.url, rawURL.standardizedFileURL)
        XCTAssertEqual(descriptor.id, descriptor.url.path)
        XCTAssertEqual(descriptor.id, rawURL.standardizedFileURL.path)
    }

    func testFileSystemAppCatalogReturnsEmptyForEmptyDirectory() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let catalog = FileSystemAppCatalog(searchDirectories: [root])
        let descriptors = try await catalog.scan()

        XCTAssertTrue(descriptors.isEmpty)
    }

    func testFileSystemAppCatalogSortsDescriptorsByDisplayName() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        try makeApplicationBundle(directoryName: "zeta.app", displayName: "Zeta", in: root)
        try makeApplicationBundle(directoryName: "alpha.app", displayName: "Alpha", in: root)
        try makeApplicationBundle(directoryName: "beta.app", displayName: "Beta", in: root)

        let catalog = FileSystemAppCatalog(searchDirectories: [root])
        let descriptors = try await catalog.scan()

        XCTAssertEqual(descriptors.map(\.name), ["Alpha", "Beta", "Zeta"])
    }

    func testViewModelLoadsAndFiltersApplications() async {
        let apps = [
            AppDescriptor(name: "Safari", url: URL(fileURLWithPath: "/Applications/Safari.app")),
            AppDescriptor(name: "Notes", url: URL(fileURLWithPath: "/Applications/Notes.app")),
            AppDescriptor(name: "Xcode", url: URL(fileURLWithPath: "/Applications/Xcode.app"))
        ]
        let viewModel = makeViewModel(with: apps)

        await viewModel.loadApps()?.value

        XCTAssertEqual(viewModel.apps, apps)
        XCTAssertEqual(viewModel.filteredApps, apps)

        viewModel.query = "code"
        XCTAssertEqual(viewModel.filteredApps.map(\.name), ["Xcode"])
        XCTAssertEqual(viewModel.selectedApp?.name, "Xcode")
    }

    func testViewModelClampsSelectionWhenFilteringResults() async {
        let apps = [
            AppDescriptor(name: "Safari", url: URL(fileURLWithPath: "/Applications/Safari.app")),
            AppDescriptor(name: "Notes", url: URL(fileURLWithPath: "/Applications/Notes.app")),
            AppDescriptor(name: "Xcode", url: URL(fileURLWithPath: "/Applications/Xcode.app"))
        ]
        let viewModel = makeViewModel(with: apps)

        await viewModel.loadApps()?.value
        viewModel.moveSelection(by: 2)
        viewModel.query = "safari"

        XCTAssertEqual(viewModel.selectedIndex, 0)
        XCTAssertEqual(viewModel.selectedApp?.name, "Safari")
    }

    func testViewModelLaunchesApplicationThroughApplicationUseCase() async {
        let application = AppDescriptor(
            name: "Demo",
            url: URL(fileURLWithPath: "/Applications/Demo.app")
        )
        let launcher = StubApplicationLauncher()
        let viewModel = LauncherViewModel(
            discoverApplications: DiscoverApplications(
                catalog: StubAppCatalog(descriptors: [])
            ),
            launchApplication: LaunchApplication(launcher: launcher)
        )

        await viewModel.launch(application)?.value

        XCTAssertEqual(launcher.launchedApplications, [application])
        XCTAssertFalse(viewModel.isLaunching)
    }

    func testViewModelPublishesLoadedStateAfterDiscovery() async {
        let viewModel = makeViewModel(with: [])

        await viewModel.loadApps()?.value

        XCTAssertEqual(viewModel.loadState, .loaded)
    }

    func testViewModelPublishesDiscoveryFailure() async {
        let viewModel = LauncherViewModel(
            discoverApplications: DiscoverApplications(catalog: ThrowingAppCatalog()),
            launchApplication: LaunchApplication(launcher: StubApplicationLauncher())
        )

        await viewModel.loadApps()?.value

        XCTAssertEqual(viewModel.errorMessage, "无法加载应用列表：目录不可用")
        XCTAssertEqual(viewModel.loadState, .failed("无法加载应用列表：目录不可用"))
    }

    func testViewModelPublishesLaunchFailure() async {
        let application = AppDescriptor(
            name: "Demo",
            url: URL(fileURLWithPath: "/Applications/Demo.app")
        )
        let viewModel = LauncherViewModel(
            discoverApplications: DiscoverApplications(catalog: StubAppCatalog(descriptors: [])),
            launchApplication: LaunchApplication(launcher: ThrowingApplicationLauncher())
        )

        await viewModel.launch(application)?.value

        XCTAssertEqual(viewModel.launchErrorMessage, "无法启动 Demo：启动失败")
        XCTAssertEqual(viewModel.launchState, .failed("无法启动 Demo：启动失败"))
    }

    private func makeViewModel(with descriptors: [AppDescriptor]) -> LauncherViewModel {
        LauncherViewModel(
            discoverApplications: DiscoverApplications(
                catalog: StubAppCatalog(descriptors: descriptors)
            ),
            launchApplication: LaunchApplication(
                launcher: StubApplicationLauncher()
            )
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OITests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func makeApplicationBundle(
        directoryName: String,
        displayName: String,
        in root: URL
    ) throws -> URL {
        let bundleURL = root.appendingPathComponent(directoryName, isDirectory: true)
        let contentsURL = bundleURL.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contentsURL, withIntermediateDirectories: true)

        let info: [String: Any] = [
            "CFBundleDisplayName": displayName,
            "CFBundleName": displayName,
            "CFBundlePackageType": "APPL"
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try data.write(to: contentsURL.appendingPathComponent("Info.plist"))
        return bundleURL
    }
}

private struct StubAppCatalog: AppCatalog {
    let descriptors: [AppDescriptor]

    func scan() async throws -> [AppDescriptor] {
        try Task.checkCancellation()
        return descriptors
    }
}

private struct ThrowingAppCatalog: AppCatalog {
    enum CatalogError: LocalizedError {
        case unavailable

        var errorDescription: String? { "目录不可用" }
    }

    func scan() async throws -> [AppDescriptor] {
        throw CatalogError.unavailable
    }
}

@MainActor
private final class StubApplicationLauncher: ApplicationLaunching {
    private(set) var launchedApplications: [AppDescriptor] = []

    func launch(_ application: AppDescriptor) async throws {
        launchedApplications.append(application)
    }
}

@MainActor
private final class ThrowingApplicationLauncher: ApplicationLaunching {
    enum LaunchError: LocalizedError {
        case failed

        var errorDescription: String? { "启动失败" }
    }

    func launch(_ application: AppDescriptor) async throws {
        throw LaunchError.failed
    }
}
