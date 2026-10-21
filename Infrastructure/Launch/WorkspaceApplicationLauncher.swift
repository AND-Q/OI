import AppKit

@MainActor
final class WorkspaceApplicationLauncher: ApplicationLaunching {
    func launch(_ application: AppDescriptor) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            NSWorkspace.shared.openApplication(
                at: application.url,
                configuration: NSWorkspace.OpenConfiguration()
            ) { @Sendable _, error in
                // 完成回调在后台队列执行：显式标为 @Sendable，Swift 6 下才不会被当作主线程闭包而在运行时断言失败。
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }
}
