import Foundation

@MainActor
struct OpenURL {
    private let opener: any URLOpening

    init(opener: any URLOpening) {
        self.opener = opener
    }

    func execute(_ url: URL) async throws {
        do {
            try await opener.open(url)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ApplicationError.urlOpenFailed(reason: error.localizedDescription)
        }
    }
}
