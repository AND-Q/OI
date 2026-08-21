import Foundation

@MainActor
struct LaunchApplication {
    private let launcher: any ApplicationLaunching

    init(launcher: any ApplicationLaunching) {
        self.launcher = launcher
    }

    func execute(_ application: AppDescriptor) async throws {
        do {
            try await launcher.launch(application)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ApplicationError.launchFailed(
                applicationName: application.name,
                reason: error.localizedDescription
            )
        }
    }
}
