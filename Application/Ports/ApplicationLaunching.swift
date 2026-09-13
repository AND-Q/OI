import Foundation

/// 用于启动领域应用的应用层端口。
@MainActor
protocol ApplicationLaunching {
    func launch(_ application: AppDescriptor) async throws
}
