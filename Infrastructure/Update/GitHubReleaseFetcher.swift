import Foundation

/// 经 GitHub REST API 查询仓库的最新 Release（`GET /repos/{owner}/{repo}/releases/latest`，
/// 不含草稿与预发布版本）。不登录访问，每个 IP 每小时限 60 次，手动检查足够使用。
struct GitHubReleaseFetcher: LatestReleaseFetching {
    static let timeout: TimeInterval = 15

    private let repository: String
    private let session: URLSession

    /// `repository` 为 `所有者/仓库名`，如 `AND-Q/OI`。
    init(repository: String, session: URLSession = .shared) {
        self.repository = repository
        self.session = session
    }

    func fetchLatestRelease() async throws -> LatestRelease {
        let result: (Data, URLResponse)
        do {
            result = try await session.data(for: Self.makeRequest(repository: repository))
        } catch {
            throw GitHubReleaseError.unreachable
        }
        let (data, response) = result
        return try Self.release(from: data, status: (response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    static func makeRequest(repository: String) -> URLRequest {
        let url = URL(string: "https://api.github.com/repos")!
            .appending(path: "\(repository)/releases/latest")
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        // GitHub 的响应允许缓存 60 秒；用户手动检查时要拿到刚发布的版本。
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        return request
    }

    /// 按状态码解析响应：仓库没有发布过版本（或仓库不公开）时 GitHub 返回 404，
    /// 超出不登录访问的次数限制时返回 403 或 429。
    static func release(from data: Data, status: Int) throws -> LatestRelease {
        switch status {
        case 200..<300:
            guard let payload = try? JSONDecoder().decode(ReleasePayload.self, from: data) else {
                throw GitHubReleaseError.invalidResponse
            }
            return LatestRelease(tagName: payload.tagName, notes: payload.body ?? "", pageURL: payload.htmlURL)
        case 404:
            throw GitHubReleaseError.notFound
        case 403, 429:
            throw GitHubReleaseError.rateLimited
        default:
            throw GitHubReleaseError.httpStatus(status)
        }
    }

    private struct ReleasePayload: Decodable {
        let tagName: String
        let body: String?
        let htmlURL: URL

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case body
            case htmlURL = "html_url"
        }
    }
}

enum GitHubReleaseError: LocalizedError, Equatable, Sendable {
    case unreachable
    case notFound
    case rateLimited
    case httpStatus(Int)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .unreachable:
            String(localized: "无法连接到 GitHub，请检查网络后重试。")
        case .notFound:
            String(localized: "在 GitHub 上没有找到已发布的版本。")
        case .rateLimited:
            String(localized: "GitHub 暂时限制了访问次数，请稍后再试。")
        case .httpStatus(let status):
            String(localized: "GitHub 返回错误（状态码 \(status)），请稍后再试。")
        case .invalidResponse:
            String(localized: "无法识别 GitHub 返回的版本信息。")
        }
    }
}
