import Foundation
import ServiceManagement

/// 基于 `SMAppService.mainApp` 的登录项实现（旧 SMLoginItemSetEnabled 的现代替代）。
/// 注册结果可能需要在 系统设置 → 通用 → 登录项与扩展 中由用户批准。
@MainActor
final class SMAppServiceLoginItemController: LoginItemControlling {
    var status: LoginItemStatus {
        switch SMAppService.mainApp.status {
        case .enabled: .enabled
        case .requiresApproval: .requiresApproval
        case .notRegistered, .notFound: .notRegistered
        }
    }

    func register() throws {
        try SMAppService.mainApp.register()
    }

    func unregister() throws {
        try SMAppService.mainApp.unregister()
    }
}
