import Foundation
import XCTest

@testable import OI

@MainActor
final class UpdateCheckTests: XCTestCase {
    // MARK: - 版本号

    func testVersionAcceptsTagPrefixAndRejectsNonNumericParts() {
        XCTAssertEqual(AppVersion("v1.2.0")?.components, [1, 2, 0])
        XCTAssertEqual(AppVersion(" 1.10 ")?.components, [1, 10])
        XCTAssertEqual(AppVersion("V2")?.description, "2")
        for invalid in ["", "v", "1..2", "1.2.0-beta", "nightly", "1.-2"] {
            XCTAssertNil(AppVersion(invalid), invalid)
        }
    }

    func testVersionComparisonIsNumericAndTreatsMissingPartsAsZero() throws {
        func version(_ string: String) throws -> AppVersion {
            try XCTUnwrap(AppVersion(string))
        }
        XCTAssertEqual(try version("1.2"), try version("1.2.0"))
        XCTAssertGreaterThan(try version("1.10.0"), try version("1.9.9"))
        XCTAssertGreaterThan(try version("2.0"), try version("1.99.99"))
        XCTAssertLessThan(try version("1.2.0"), try version("1.2.1"))
    }

    // MARK: - 用例

    func testCheckReportsUpdateOnlyWhenLatestReleaseIsNewer() async throws {
        let newer = release("v1.1.0")
        let result = try await CheckForUpdates(
            fetcher: StubReleaseFetcher(result: .success(newer)),
            currentVersion: "1.0.0"
        ).execute()
        XCTAssertEqual(
            result,
            .updateAvailable(
                currentVersion: try XCTUnwrap(AppVersion("1.0.0")),
                latestVersion: try XCTUnwrap(AppVersion("1.1.0")),
                release: newer
            )
        )

        // 已是同一版本，或本地的开发版本比最新发布的还新。
        for current in ["1.1.0", "1.1", "1.2.0"] {
            let result = try await CheckForUpdates(
                fetcher: StubReleaseFetcher(result: .success(newer)),
                currentVersion: current
            ).execute()
            XCTAssertEqual(result, .upToDate(currentVersion: try XCTUnwrap(AppVersion(current))), current)
        }
    }

    func testCheckFailsWithReadableReason() async {
        await assertCheckFails(
            .failure(.rateLimited),
            currentVersion: "1.0.0",
            reason: "GitHub 暂时限制了访问次数，请稍后再试。"
        )
        await assertCheckFails(
            .success(release("nightly")),
            currentVersion: "1.0.0",
            reason: "无法识别最新版本的版本号「nightly」。"
        )
        await assertCheckFails(
            .success(release("v1.1.0")),
            currentVersion: "",
            reason: "无法识别当前版本号「」。"
        )
    }

    // MARK: - GitHub

    func testGitHubRequestTargetsLatestReleaseOfRepository() {
        let request = GitHubReleaseFetcher.makeRequest(repository: "AND-Q/OI")
        XCTAssertEqual(request.url?.absoluteString, "https://api.github.com/repos/AND-Q/OI/releases/latest")
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/vnd.github+json")
        XCTAssertEqual(request.cachePolicy, .reloadIgnoringLocalCacheData)
    }

    func testGitHubResponseParsing() throws {
        let json = Data("""
        {
          "tag_name": "v1.1.0",
          "name": "OI 1.1.0",
          "body": "# OI 1.1.0\\n\\n- 新功能",
          "html_url": "https://github.com/AND-Q/OI/releases/tag/v1.1.0",
          "draft": false,
          "prerelease": false
        }
        """.utf8)
        XCTAssertEqual(
            try GitHubReleaseFetcher.release(from: json, status: 200),
            LatestRelease(
                tagName: "v1.1.0",
                notes: "# OI 1.1.0\n\n- 新功能",
                pageURL: try XCTUnwrap(URL(string: "https://github.com/AND-Q/OI/releases/tag/v1.1.0"))
            )
        )

        // 没有填写发布说明时 body 为 null。
        let withoutNotes = Data("""
        {"tag_name": "v1.1.0", "body": null, "html_url": "https://github.com/AND-Q/OI/releases/tag/v1.1.0"}
        """.utf8)
        XCTAssertEqual(try GitHubReleaseFetcher.release(from: withoutNotes, status: 200).notes, "")
    }

    func testGitHubErrorStatusesMapToReadableErrors() {
        func failure(status: Int, body: String = "{}") -> GitHubReleaseError? {
            do {
                _ = try GitHubReleaseFetcher.release(from: Data(body.utf8), status: status)
                return nil
            } catch {
                return error as? GitHubReleaseError
            }
        }
        XCTAssertEqual(failure(status: 404), .notFound)
        XCTAssertEqual(failure(status: 403), .rateLimited)
        XCTAssertEqual(failure(status: 429), .rateLimited)
        XCTAssertEqual(failure(status: 500), .httpStatus(500))
        XCTAssertEqual(failure(status: 200, body: "not json"), .invalidResponse)
    }

    // MARK: - 提醒框控制器

    func testControllerOpensReleasePageOnlyWhenDownloadIsChosen() async throws {
        let newer = release("v1.1.0")
        for choosesDownload in [true, false] {
            let opener = StubURLOpener()
            var outcomes: [UpdateCheckController.Outcome] = []
            let controller = UpdateCheckController(
                checkForUpdates: CheckForUpdates(
                    fetcher: StubReleaseFetcher(result: .success(newer)),
                    currentVersion: "1.0.0"
                ),
                openURL: OpenURL(opener: opener),
                showAlert: { outcome in
                    outcomes.append(outcome)
                    return choosesDownload
                }
            )

            await controller.check()

            XCTAssertEqual(outcomes, [
                .checked(.updateAvailable(
                    currentVersion: try XCTUnwrap(AppVersion("1.0.0")),
                    latestVersion: try XCTUnwrap(AppVersion("1.1.0")),
                    release: newer
                )),
            ])
            XCTAssertEqual(opener.openedURLs, choosesDownload ? [newer.pageURL] : [])
            XCTAssertFalse(controller.isChecking)
        }
    }

    func testControllerReportsUpToDateAndFailureWithoutOpeningAnything() async throws {
        let opener = StubURLOpener()
        var outcomes: [UpdateCheckController.Outcome] = []
        for result: Result<LatestRelease, GitHubReleaseError> in [.success(release("v1.0.0")), .failure(.unreachable)] {
            let controller = UpdateCheckController(
                checkForUpdates: CheckForUpdates(fetcher: StubReleaseFetcher(result: result), currentVersion: "1.0.0"),
                openURL: OpenURL(opener: opener),
                showAlert: { outcome in
                    outcomes.append(outcome)
                    return true
                }
            )
            await controller.check()
        }

        XCTAssertEqual(outcomes, [
            .checked(.upToDate(currentVersion: try XCTUnwrap(AppVersion("1.0.0")))),
            .failed(reason: "无法连接到 GitHub，请检查网络后重试。"),
        ])
        XCTAssertEqual(opener.openedURLs, [])
    }

    /// 发布说明开头的一级标题与提醒框标题重复，不再显示；其余内容原样保留。
    func testReleaseNotesDropLeadingTitle() {
        XCTAssertEqual(
            UpdateCheckController.releaseNoteBlocks(from: "# OI 1.1.0\n\n新功能\n\n## 修复"),
            [.paragraph("新功能"), .heading(level: 2, text: "修复")]
        )
        XCTAssertEqual(
            UpdateCheckController.releaseNoteBlocks(from: "## 功能\n\n说明"),
            [.heading(level: 2, text: "功能"), .paragraph("说明")]
        )
        XCTAssertEqual(UpdateCheckController.releaseNoteBlocks(from: ""), [])
    }

    // MARK: - 辅助方法

    private func release(_ tagName: String) -> LatestRelease {
        LatestRelease(
            tagName: tagName,
            notes: "",
            pageURL: URL(string: "https://github.com/AND-Q/OI/releases/tag/\(tagName)")!
        )
    }

    private func assertCheckFails(
        _ result: Result<LatestRelease, GitHubReleaseError>,
        currentVersion: String,
        reason: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await CheckForUpdates(
                fetcher: StubReleaseFetcher(result: result),
                currentVersion: currentVersion
            ).execute()
            XCTFail("应当检查失败", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? ApplicationError, .updateCheckFailed(reason: reason), file: file, line: line)
        }
    }
}

private struct StubReleaseFetcher: LatestReleaseFetching {
    let result: Result<LatestRelease, GitHubReleaseError>

    func fetchLatestRelease() async throws -> LatestRelease {
        try result.get()
    }
}
