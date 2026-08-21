import Foundation

/// State owned by the launcher feature while its application catalog is loaded.
enum LauncherLoadState: Equatable, Sendable {
    case idle
    case loading
    case loaded
    case failed(String)
}

/// State owned by the launcher feature while an application is launched.
enum LauncherLaunchState: Equatable, Sendable {
    case idle
    case launching
    case failed(String)
}
