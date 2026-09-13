import CoreServices
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

            // When a configured path points directly to an application bundle
            // (e.g. /System/Library/CoreServices/Finder.app), record it directly
            // rather than enumerating inside its package.
            if directory.pathExtension.caseInsensitiveCompare("app") == .orderedSame {
                let resolvedURL = directory.resolvingSymlinksInPath().standardizedFileURL
                guard seenPaths.insert(resolvedURL.path).inserted else {
                    continue
                }
                if let descriptor = makeDescriptor(bundleURL: resolvedURL) {
                    descriptors.append(descriptor)
                }
                continue
            }

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
        let displayName = localizedDisplayName(bundleURL: bundleURL, bundle: bundle)
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

    /// Reads the user-facing localized display name using bundle localization resources,
    /// Spotlight metadata, or standard bundle info keys.
    private static func localizedDisplayName(bundleURL: URL, bundle: Bundle?) -> String {
        let fsBaseName = bundleURL.deletingPathExtension().lastPathComponent

        // 1. Read localized InfoPlist.strings matching the user's preferred languages.
        // Third-party applications or newly unpacked bundles provide localized display
        // names here (e.g. zh-Hans.lproj/InfoPlist.strings -> "微信").
        let preferredLanguages = Locale.preferredLanguages
        let localizations = bundle?.localizations ?? []
        let matched = Bundle.preferredLocalizations(from: localizations, forPreferences: preferredLanguages)
        if let bestLang = matched.first,
           let path = bundle?.path(forResource: "InfoPlist", ofType: "strings", inDirectory: nil, forLocalization: bestLang),
           let dict = NSDictionary(contentsOfFile: path) as? [String: Any] {
            if let localizedName = (dict["CFBundleDisplayName"] as? String) ?? (dict["CFBundleName"] as? String) {
                let trimmed = localizedName.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
        }

        // 2. Query Spotlight metadata directly: macOS indexes system applications
        // (e.g. Notes -> "备忘录", Finder -> "访达") and applications whose display
        // names are registered in the system LaunchServices database.
        if let item = MDItemCreateWithURL(kCFAllocatorDefault, bundleURL as CFURL),
           let rawName = MDItemCopyAttribute(item, kMDItemDisplayName) as? String {
            let trimmed = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
            let stripped = trimmed.hasSuffix(".app") ? String(trimmed.dropLast(4)) : trimmed
            let candidate = stripped.trimmingCharacters(in: .whitespacesAndNewlines)
            if !candidate.isEmpty {
                return candidate
            }
        }

        // 3. Fall back to standard bundle dictionary lookups or filesystem name.
        let fallback = (bundle?.localizedInfoDictionary?["CFBundleDisplayName"] as? String)
            ?? (bundle?.localizedInfoDictionary?["CFBundleName"] as? String)
            ?? (bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? fsBaseName

        return fallback.trimmingCharacters(in: .whitespacesAndNewlines)
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
