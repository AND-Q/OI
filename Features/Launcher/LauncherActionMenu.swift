import Foundation

/// Cmd+K 快捷操作菜单中可执行的动作。
enum ResultMenuAction: CaseIterable, Hashable, Sendable {
    case revealInFinder
    case copyPath
    case copyBundleID
    case openInTerminal
    case openWith

    var title: String {
        switch self {
        case .revealInFinder: String(localized: "在 Finder 中显示")
        case .copyPath: String(localized: "复制路径")
        case .copyBundleID: String(localized: "复制 Bundle ID")
        case .openInTerminal: String(localized: "在终端中打开")
        case .openWith: String(localized: "用其他 App 打开…")
        }
    }

    var systemImage: String {
        switch self {
        case .revealInFinder: "folder"
        case .copyPath: "doc.on.doc"
        case .copyBundleID: "number"
        case .openInTerminal: "terminal"
        case .openWith: "arrow.up.forward.app"
        }
    }

    var shortcutKeys: [String] {
        switch self {
        case .revealInFinder: ["⌘", "F"]
        case .copyPath: ["⌥", "⌘", "C"]
        case .copyBundleID: ["⌘", "B"]
        case .openInTerminal: ["⌘", "T"]
        case .openWith: []
        }
    }
}

/// 选中结果的快捷操作提供器：按结果类型给出可用动作。
enum LauncherActionMenu {
    /// 当前结果可用的动作列表（保持一致且可预测的顺序）。
    static func availableActions(for result: SearchResult) -> [ResultMenuAction] {
        var actions: [ResultMenuAction] = []
        if let url = result.url, url.isFileURL {
            actions.append(.revealInFinder)
            actions.append(.copyPath)
        }
        if case .application(let app) = result, app.bundleIdentifier != nil {
            actions.append(.copyBundleID)
        }
        if result.terminalDirectory != nil {
            actions.append(.openInTerminal)
        }
        // 只给文件与文件夹：应用本身直接启动，用编辑器打开 .app 包没有意义。
        if case .file = result {
            actions.append(.openWith)
        }
        return actions
    }
}
