import AppKit

@MainActor
final class WorkspaceApplicationLauncher: ApplicationLaunching {
    func launch(_ application: AppDescriptor) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            NSWorkspace.shared.openApplication(
                at: application.url,
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
