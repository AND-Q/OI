import Carbon.HIToolbox
import Foundation

/// Values that can vary between app distributions or test environments.
struct AppConfiguration: Sendable {
    struct Shortcut: Sendable {
        let keyCode: UInt32
        let modifiers: UInt32
    }

    let applicationSearchDirectories: [URL]
    let launcherShortcut: Shortcut

    static let live = AppConfiguration(
        applicationSearchDirectories: [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications", isDirectory: true)
        ],
        launcherShortcut: Shortcut(
            keyCode: UInt32(kVK_Space),
            modifiers: UInt32(optionKey)
        )
    )
}
