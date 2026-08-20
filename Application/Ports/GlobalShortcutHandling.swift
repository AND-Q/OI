import Foundation

/// Application-layer port for the app-wide shortcut lifecycle.
@MainActor
protocol GlobalShortcutHandling: AnyObject {
    func register(keyCode: UInt32, modifiers: UInt32, handler: @escaping () -> Void) throws
    func unregister()
}
