import Combine
import Foundation

@MainActor
final class LauncherViewModel: ObservableObject {
    @Published var query = "" {
        didSet { updateFilteredApps() }
    }
    @Published private(set) var apps: [AppDescriptor] = []
    @Published private(set) var filteredApps: [AppDescriptor] = []
    @Published private(set) var selectedIndex = 0
    @Published private(set) var isLoading = false
    @Published private(set) var focusRequest = 0
    @Published private(set) var errorMessage: String?
    @Published private(set) var isLaunching = false
    @Published private(set) var launchErrorMessage: String?

    private let discoverApplications: DiscoverApplications
    private let launchApplication: LaunchApplication
    private var loadTask: Task<Void, Never>?
    private var launchTask: Task<Void, Never>?

    init(
        discoverApplications: DiscoverApplications,
        launchApplication: LaunchApplication
    ) {
        self.discoverApplications = discoverApplications
        self.launchApplication = launchApplication
    }

    deinit {
        loadTask?.cancel()
        launchTask?.cancel()
    }

    var selectedApp: AppDescriptor? {
        guard filteredApps.indices.contains(selectedIndex) else { return nil }
        return filteredApps[selectedIndex]
    }

    @discardableResult
    func loadApps() -> Task<Void, Never>? {
        guard loadTask == nil else { return loadTask }
        guard apps.isEmpty else { return nil }

        isLoading = true
        errorMessage = nil
        let discoverApplications = self.discoverApplications

        loadTask = Task { [weak self] in
            do {
                let descriptors = try await discoverApplications.execute()
                try Task.checkCancellation()

                guard let self else { return }
                apps = descriptors
                updateFilteredApps()
            } catch is CancellationError {
                // Cancellation is an expected lifecycle event.
            } catch {
                self?.errorMessage = error.localizedDescription
            }

            self?.finishLoading()
        }

        return loadTask
    }

    @discardableResult
    func launch(_ application: AppDescriptor) -> Task<Void, Never>? {
        guard launchTask == nil else { return launchTask }

        isLaunching = true
        launchErrorMessage = nil
        let launchApplication = self.launchApplication

        launchTask = Task { [weak self] in
            do {
                try await launchApplication.execute(application)
            } catch is CancellationError {
                // Cancellation is an expected lifecycle event.
            } catch {
                self?.launchErrorMessage = error.localizedDescription
            }

            self?.finishLaunching()
        }

        return launchTask
    }

    func cancelOperations() {
        loadTask?.cancel()
        launchTask?.cancel()
        isLoading = false
        isLaunching = false
    }

    func prepareForPresentation() {
        query = ""
        selectedIndex = 0
        updateFilteredApps()
    }

    func requestFocus() {
        focusRequest &+= 1
    }

    func moveSelection(by offset: Int) {
        guard !filteredApps.isEmpty else { return }
        selectedIndex = min(max(selectedIndex + offset, 0), filteredApps.count - 1)
    }

    private func finishLoading() {
        isLoading = false
        loadTask = nil
    }

    private func finishLaunching() {
        isLaunching = false
        launchTask = nil
    }

    private func updateFilteredApps() {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        filteredApps = normalizedQuery.isEmpty
            ? apps
            : apps.filter { $0.name.localizedCaseInsensitiveContains(normalizedQuery) }

        if filteredApps.isEmpty {
            selectedIndex = 0
        } else {
            selectedIndex = min(selectedIndex, filteredApps.count - 1)
        }
    }
}
