import Foundation

/// Application-layer port for discovering launchable applications.
protocol AppCatalog: Sendable {
    func scan() async throws -> [AppDescriptor]
}
