import Foundation

/// 用于发现可启动应用的应用层端口。
protocol AppCatalog: Sendable {
    func scan() async throws -> [AppDescriptor]
}
