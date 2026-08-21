import Foundation

/// Errors exposed by application use cases. Platform-specific errors stay below this boundary.
enum ApplicationError: Error, Equatable, Sendable {
    case discoveryFailed(reason: String)
    case launchFailed(applicationName: String, reason: String)
}
