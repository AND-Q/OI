import Foundation

/// Cmd+K 快捷操作菜单中可执行的动作。
enum ResultMenuAction: CaseIterable, Hashable, Sendable {
    case revealInFinder
    case copyPath
    case copyBundleID
    case openInTerminal

    var title: String {
        switch self {
        case .revealInFinder: return "在 Finder 中显示"
        case .copyPath: return "复制路径"
        case .copyBundleID: return "复制 Bundle ID"
        case .openInTerminal: return "在终端中打开"
        }
    }

    var systemImage: String {
        switch self {
        case .revealInFinder: return "folder"
        case .copyPath: return "doc.on.doc"
        case .copyBundleID: return "number"
        case .openInTerminal: return "terminal"
        }
    }

    var shortcutKeys: [String] {
        switch self {
        case .revealInFinder: return ["⌘", "F"]
        case .copyPath: return ["⌥", "⌘", "C"]
        case .copyBundleID: return ["⌘", "B"]
        case .openInTerminal: return ["⌘", "T"]
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
        return actions
    }
}
