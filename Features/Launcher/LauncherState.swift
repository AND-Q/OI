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

/// State owned by the launcher feature while the file index is queried.
/// Failures degrade silently to an empty file section, so there is no failed case.
enum LauncherFileSearchState: Equatable, Sendable {
    case idle
    case searching
    case loaded
}

/// One row of the results list: selectable results plus non-selectable section headers.
enum LauncherRow: Hashable, Sendable {
    case sectionHeader(String)
    case result(SearchResult)
}
