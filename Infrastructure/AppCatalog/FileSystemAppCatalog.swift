import Foundation

struct FileSystemAppCatalog: AppCatalog, Sendable {
    let searchDirectories: [URL]

    init(searchDirectories: [URL] = FileSystemAppCatalog.defaultSearchDirectories) {
        self.searchDirectories = searchDirectories
    }

    func scan() async throws -> [AppDescriptor] {
        let searchDirectories = searchDirectories
        let worker = Task.detached(priority: .userInitiated) {
            try Self.scanSynchronously(in: searchDirectories)
        }

        return try await withTaskCancellationHandler(operation: {
            try await worker.value
        }, onCancel: {
            worker.cancel()
        })
    }

    private static func scanSynchronously(in searchDirectories: [URL]) throws -> [AppDescriptor] {
        let fileManager = FileManager.default
        var descriptors: [AppDescriptor] = []
        var seenPaths = Set<String>()

        for directory in searchDirectories {
            try Task.checkCancellation()

            guard let enumerator = fileManager.enumerator(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else {
                continue
            }

            for case let url as URL in enumerator {
                try Task.checkCancellation()

                guard url.pathExtension.caseInsensitiveCompare("app") == .orderedSame else {
                    continue
                }

                let standardizedURL = url.standardizedFileURL
                guard seenPaths.insert(standardizedURL.path).inserted else {
                    continue
                }

                let bundle = Bundle(url: standardizedURL)
                let displayName = (bundle?.localizedInfoDictionary?["CFBundleDisplayName"] as? String)
                    ?? (bundle?.localizedInfoDictionary?["CFBundleName"] as? String)
                    ?? (bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                    ?? (bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String)
                    ?? standardizedURL.deletingPathExtension().lastPathComponent
                let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)

                guard !name.isEmpty else { continue }
                descriptors.append(AppDescriptor(name: name, url: standardizedURL))
            }
        }

        return descriptors.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    private static var defaultSearchDirectories: [URL] {
        [
            URL(fileURLWithPath: "/Applications"),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications"),
            URL(fileURLWithPath: "/System/Applications")
        ]
    }
}
