import Foundation

/// 用于打开文件或在文件管理器中定位条目的应用层端口。
@MainActor
protocol FileOpening {
    func open(_ file: FileDescriptor) async throws
    func revealInFinder(url: URL)
}
