import Foundation

/// Application-layer port for launching a domain application.
@MainActor
protocol ApplicationLaunching {
    func launch(_ application: AppDescriptor) async throws
}
