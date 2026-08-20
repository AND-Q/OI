import Foundation

@MainActor
struct LaunchApplication {
    private let launcher: any ApplicationLaunching

    init(launcher: any ApplicationLaunching) {
        self.launcher = launcher
    }

    func execute(_ application: AppDescriptor) async throws {
        try await launcher.launch(application)
    }
}
