import Foundation

@MainActor
struct OpenFile {
    private let opener: any FileOpening

    init(opener: any FileOpening) {
        self.opener = opener
    }

    func execute(_ file: FileDescriptor) async throws {
        do {
            try await opener.open(file)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ApplicationError.fileOpenFailed(
                fileName: file.name,
                reason: error.localizedDescription
            )
        }
    }

    func reveal(url: URL) {
        opener.revealInFinder(url: url)
    }

    func openInTerminal(url: URL) {
        opener.openInTerminal(url: url)
    }
}
