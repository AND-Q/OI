import AppKit

@MainActor
final class WorkspaceFileOpener: FileOpening {
    func open(_ file: FileDescriptor) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            NSWorkspace.shared.open(
                file.url,
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

    func revealInFinder(url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// 用系统终端打开目录，等价于 `open -a Terminal <目录>`。
    func openInTerminal(url: URL) {
        guard let terminalURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else { return }
        NSWorkspace.shared.open(
            [url],
            withApplicationAt: terminalURL,
            configuration: NSWorkspace.OpenConfiguration()
        )
    }
}
