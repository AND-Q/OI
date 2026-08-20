import Foundation

struct DiscoverApplications: Sendable {
    private let catalog: any AppCatalog

    init(catalog: any AppCatalog) {
        self.catalog = catalog
    }

    func execute() async throws -> [AppDescriptor] {
        try await catalog.scan()
    }
}
