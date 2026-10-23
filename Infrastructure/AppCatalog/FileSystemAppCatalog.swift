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

            // 配置的路径直接指向应用包（如 /System/Library/CoreServices/Finder.app）时直接记录，不进入包内遍历。
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

                // 去重前先解析符号链接，同一个应用包经两个路径发现时只出现一次。
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

    /// 读取面向用户的本地化显示名：依次尝试应用包的本地化资源、Spotlight 元数据与标准的 Info.plist 键。
    private static func localizedDisplayName(bundleURL: URL, bundle: Bundle?) -> String {
        let fsBaseName = bundleURL.deletingPathExtension().lastPathComponent

        // 1. 读取与用户首选语言匹配的本地化 InfoPlist.strings：第三方应用或刚解压的应用包
        // 在这里提供本地化显示名（如 zh-Hans.lproj/InfoPlist.strings -> "微信"）。
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

        // 2. 直接查询 Spotlight 元数据：macOS 为系统应用（如 Notes -> "备忘录"、Finder -> "访达"）
        // 以及显示名登记在 LaunchServices 数据库中的应用建立了索引。
        if let item = MDItemCreateWithURL(kCFAllocatorDefault, bundleURL as CFURL),
           let rawName = MDItemCopyAttribute(item, kMDItemDisplayName) as? String {
            let trimmed = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
            let stripped = trimmed.hasSuffix(".app") ? String(trimmed.dropLast(4)) : trimmed
            let candidate = stripped.trimmingCharacters(in: .whitespacesAndNewlines)
            if !candidate.isEmpty {
                return candidate
            }
        }

        // 3. 退回标准的 Info.plist 字典查找，最后用文件名。
        let fallback = (bundle?.localizedInfoDictionary?["CFBundleDisplayName"] as? String)
            ?? (bundle?.localizedInfoDictionary?["CFBundleName"] as? String)
            ?? (bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? fsBaseName

        return fallback.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 每个 Bundle Identifier 与应用包文件名的组合只保留一条，即在多个目录中发现的同一个应用：
    /// 路径层级较浅的那份胜出，层级相同时按路径比较，结果稳定。文件名不同的副本
    /// （Xcode.app 与 Xcode-beta.app 共用一个 Identifier）是有意分开安装的，全部保留。
    private static func deduplicateByIdentifier(_ descriptors: [AppDescriptor]) -> [AppDescriptor] {
        var bestByKey: [String: AppDescriptor] = [:]
        var unkeyed: [AppDescriptor] = []

        for descriptor in descriptors {
            guard let identifier = descriptor.bundleIdentifier else {
                unkeyed.append(descriptor)
                continue
            }
            let key = identifier + "/" + descriptor.url.lastPathComponent
            if let current = bestByKey[key],
               !preferred(descriptor, over: current) {
                continue
            }
            bestByKey[key] = descriptor
        }

        return unkeyed + bestByKey.values
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
