import Foundation
import XCTest

@testable import OI

@MainActor
final class FileSystemAppCatalogTests: XCTestCase {
    // MARK: - 扫描

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

    func testFileSystemAppCatalogReadsBundleIdentifier() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        try makeApplicationBundle(
            directoryName: "demo.app",
            displayName: "Demo",
            bundleIdentifier: "com.example.demo",
            in: root
        )

        let catalog = FileSystemAppCatalog(searchDirectories: [root])
        let descriptors = try await catalog.scan()

        XCTAssertEqual(descriptors.first?.bundleIdentifier, "com.example.demo")
    }

    func testFileSystemAppCatalogReadsLocalizedInfoPlistStrings() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let bundleURL = root.appendingPathComponent("WeChat.app", isDirectory: true)
        let contentsURL = bundleURL.appendingPathComponent("Contents", isDirectory: true)
        let resourcesURL = contentsURL.appendingPathComponent("Resources/zh-Hans.lproj", isDirectory: true)
        try FileManager.default.createDirectory(at: resourcesURL, withIntermediateDirectories: true)

        let info: [String: Any] = [
            "CFBundleDisplayName": "WeChat",
            "CFBundleName": "WeChat",
            "CFBundlePackageType": "APPL"
        ]
        let infoData = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try infoData.write(to: contentsURL.appendingPathComponent("Info.plist"))

        let localizedStrings = "\"CFBundleDisplayName\" = \"微信\";\n\"CFBundleName\" = \"微信\";\n"
        try localizedStrings.write(
            to: resourcesURL.appendingPathComponent("InfoPlist.strings"),
            atomically: true,
            encoding: .utf8
        )

        let catalog = FileSystemAppCatalog(searchDirectories: [root])
        let descriptors = try await catalog.scan()

        XCTAssertEqual(descriptors.first?.name, "微信")
    }

    // MARK: - 去重

    func testFileSystemAppCatalogKeepsShallowerPathForSameBundleIdentifier() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        try makeApplicationBundle(
            directoryName: "nested/Demo.app",
            displayName: "Demo",
            bundleIdentifier: "com.example.demo",
            in: root
        )
        try makeApplicationBundle(
            directoryName: "Demo.app",
            displayName: "Demo",
            bundleIdentifier: "com.example.demo",
            in: root
        )

        let catalog = FileSystemAppCatalog(searchDirectories: [root])
        let descriptors = try await catalog.scan()

        XCTAssertEqual(descriptors.count, 1)
        XCTAssertEqual(descriptors.first?.url.path, root.appendingPathComponent("Demo.app").path)
    }

    func testFileSystemAppCatalogDeduplicatesSymlinkedBundles() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let realURL = try makeApplicationBundle(
            directoryName: "Real.app",
            displayName: "Real",
            in: root
        )
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("Link.app", isDirectory: true),
            withDestinationURL: realURL
        )

        let catalog = FileSystemAppCatalog(searchDirectories: [root])
        let descriptors = try await catalog.scan()

        XCTAssertEqual(descriptors.count, 1)
        XCTAssertEqual(descriptors.first?.url, realURL)
    }

    func testFileSystemAppCatalogSkipsAppsNestedInsideOtherApps() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        try makeApplicationBundle(directoryName: "Outer.app", displayName: "Outer", in: root)
        try makeApplicationBundle(
            directoryName: "Outer.app/Contents/Inner.app",
            displayName: "Inner",
            in: root
        )

        let catalog = FileSystemAppCatalog(searchDirectories: [root])
        let descriptors = try await catalog.scan()

        XCTAssertEqual(descriptors.map(\.name), ["Outer"])
    }

    // MARK: - 搜索目录形态

    func testFileSystemAppCatalogSupportsDirectBundlePathInSearchDirectories() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let directAppURL = try makeApplicationBundle(
            directoryName: "Direct.app",
            displayName: "Direct",
            in: root
        )

        let catalog = FileSystemAppCatalog(searchDirectories: [directAppURL])
        let descriptors = try await catalog.scan()

        XCTAssertEqual(descriptors.count, 1)
        XCTAssertEqual(descriptors.first?.name, "Direct")
        XCTAssertEqual(descriptors.first?.url, directAppURL.standardizedFileURL)
    }
}
