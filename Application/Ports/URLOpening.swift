import Foundation

/// 用于在系统默认处理器（通常是默认浏览器）中打开网页地址的应用层端口。
@MainActor
protocol URLOpening {
    func open(_ url: URL) async throws
}
