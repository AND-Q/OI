import Foundation

/// 应用全局快捷键生命周期的应用层端口。
@MainActor
protocol GlobalShortcutHandling: AnyObject {
    func register(keyCode: UInt32, modifiers: UInt32, handler: @escaping () -> Void) throws
    func unregister()
}
