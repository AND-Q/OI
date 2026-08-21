import Foundation

struct DiscoverApplications: Sendable {
    private let catalog: any AppCatalog

    init(catalog: any AppCatalog) {
        self.catalog = catalog
    }

    func execute() async throws -> [AppDescriptor] {
        do {
            return try await catalog.scan()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ApplicationError.discoveryFailed(reason: error.localizedDescription)
        }
    }
}
