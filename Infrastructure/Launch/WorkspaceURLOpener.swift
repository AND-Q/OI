import AppKit

@MainActor
final class WorkspaceURLOpener: URLOpening {
    func open(_ url: URL) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            NSWorkspace.shared.open(
                url,
                configuration: NSWorkspace.OpenConfiguration()
            ) { _, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }
}
