import Foundation

struct FileSystemAppCatalog: AppCatalog, Sendable {
    let searchDirectories: [URL]

    init(searchDirectories: [URL]) {
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

                // Resolve symlinks before dedup so one bundle mounted at two
                // paths appears once.
                let resolvedURL = url.resolvingSymlinksInPath().standardizedFileURL
                guard seenPaths.insert(resolvedURL.path).inserted else {
                    continue
                }

                if let descriptor = makeDescriptor(bundleURL: resolvedURL) {
                    descriptors.append(descriptor)
                }
            }
        }

        return deduplicateByIdentifier(descriptors).sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    private static func makeDescriptor(bundleURL: URL) -> AppDescriptor? {
        let bundle = Bundle(url: bundleURL)
        let displayName = (bundle?.localizedInfoDictionary?["CFBundleDisplayName"] as? String)
            ?? (bundle?.localizedInfoDictionary?["CFBundleName"] as? String)
            ?? (bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? bundleURL.deletingPathExtension().lastPathComponent
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }

        let bundleIdentifier = (bundle?.object(forInfoDictionaryKey: "CFBundleIdentifier") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return AppDescriptor(
            name: name,
            url: bundleURL,
            bundleIdentifier: bundleIdentifier?.isEmpty == false ? bundleIdentifier : nil
        )
    }

    /// Keeps one entry per bundle identifier: the copy with the shallower path
    /// wins, with the path itself as the stable tie-break.
    private static func deduplicateByIdentifier(_ descriptors: [AppDescriptor]) -> [AppDescriptor] {
        var bestByIdentifier: [String: AppDescriptor] = [:]
        var unkeyed: [AppDescriptor] = []

        for descriptor in descriptors {
            guard let identifier = descriptor.bundleIdentifier else {
                unkeyed.append(descriptor)
                continue
            }
            if let current = bestByIdentifier[identifier],
               !preferred(descriptor, over: current) {
                continue
            }
            bestByIdentifier[identifier] = descriptor
        }

        return unkeyed + bestByIdentifier.values
    }

    private static func preferred(_ candidate: AppDescriptor, over current: AppDescriptor) -> Bool {
        let candidateDepth = candidate.url.pathComponents.count
        let currentDepth = current.url.pathComponents.count
        if candidateDepth != currentDepth {
            return candidateDepth < currentDepth
        }
        return candidate.url.path < current.url.path
    }
}
