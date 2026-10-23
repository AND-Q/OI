import Foundation

/// 用于打开文件、在文件管理器中定位条目或在终端打开所在目录的应用层端口。
@MainActor
protocol FileOpening {
    func open(_ file: FileDescriptor) async throws
    func revealInFinder(url: URL)
    func openInTerminal(url: URL)
    /// 「用其他 App 打开…」中列出的 App：系统指定的默认 App 在前，其余按名称排序。
    func applications(toOpen file: FileDescriptor) -> [OpenWithApplication]
    func open(_ file: FileDescriptor, withApplicationAt applicationURL: URL) async throws
    /// 路径直达：`path` 处实际存在的文件或文件夹，开头的 `~` 展开为用户目录；不存在时为 nil。
    /// 不经文件索引，隐藏文件与 `~/Library` 下的条目同样可以取到。路径落在无响应的网络卷上时
    /// 查看文件系统可能阻塞数秒，实现须在后台执行，不得占用主线程。
    func item(atPath path: String) async -> FileDescriptor?
}

/// 「用其他 App 打开…」菜单中的一个 App。
struct OpenWithApplication: Equatable, Sendable {
    let url: URL
    let name: String
    /// 系统为该文件指定的默认 App。
    let isDefault: Bool
}
