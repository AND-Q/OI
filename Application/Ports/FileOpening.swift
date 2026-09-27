import Foundation

/// 用于打开文件、在文件管理器中定位条目或在终端打开所在目录的应用层端口。
@MainActor
protocol FileOpening {
    func open(_ file: FileDescriptor) async throws
    func revealInFinder(url: URL)
    func openInTerminal(url: URL)
}
