import Foundation

/// 应用层用例对外暴露的错误。平台特定的错误不越过这一边界。
enum ApplicationError: Error, Equatable, Sendable {
    case discoveryFailed(reason: String)
    case launchFailed(applicationName: String, reason: String)
    case fileSearchFailed(reason: String)
    case fileOpenFailed(fileName: String, reason: String)
    case urlOpenFailed(reason: String)
    case quickAINotConfigured
    case quickAIFailed(reason: String)
    case updateCheckFailed(reason: String)
}
