import SwiftUI

@main
struct OIApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    // The menu bar process owns its custom NSPanel through AppCoordinator.
    // Settings keeps the SwiftUI App lifecycle valid without creating a window.
    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}
