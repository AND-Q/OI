import Foundation

/// 检查更新的结果。
enum UpdateCheckResult: Equatable, Sendable {
    /// 最新发布的版本比当前版本新。
    case updateAvailable(currentVersion: AppVersion, latestVersion: AppVersion, release: LatestRelease)
    /// 当前已是最新版本，包括当前版本比最新发布的还新（如尚未发布的开发版本）。
    case upToDate(currentVersion: AppVersion)
}

@MainActor
struct CheckForUpdates {
    private let fetcher: any LatestReleaseFetching
    private let currentVersion: String

    /// `currentVersion` 为当前运行的 OI 的版本号（`CFBundleShortVersionString`）。
    init(fetcher: any LatestReleaseFetching, currentVersion: String) {
        self.fetcher = fetcher
        self.currentVersion = currentVersion
    }

    /// 查询最新发布的版本并与当前版本比较；查询失败或版本号无法识别时抛出检查更新失败。
    func execute() async throws -> UpdateCheckResult {
        guard let current = AppVersion(currentVersion) else {
            throw ApplicationError.updateCheckFailed(reason: String(localized: "无法识别当前版本号「\(currentVersion)」。"))
        }
        let release: LatestRelease
        do {
            release = try await fetcher.fetchLatestRelease()
        } catch {
            throw ApplicationError.updateCheckFailed(
                reason: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            )
        }
        guard let latest = AppVersion(release.tagName) else {
            throw ApplicationError.updateCheckFailed(reason: String(localized: "无法识别最新版本的版本号「\(release.tagName)」。"))
        }
        if latest > current {
            return .updateAvailable(currentVersion: current, latestVersion: latest, release: release)
        }
        return .upToDate(currentVersion: current)
    }
}
