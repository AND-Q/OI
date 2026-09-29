import Foundation

/// 登录项在系统中的注册状态。
enum LoginItemStatus: Equatable, Sendable {
    case enabled
    /// 已注册但等待用户在系统设置中批准。
    case requiresApproval
    case notRegistered
}

/// 开机自启动（登录项）生命周期的应用层端口。
@MainActor
protocol LoginItemControlling: AnyObject {
    var status: LoginItemStatus { get }
    func register() throws
    func unregister() throws
}
