import AppKit

/// Cmd+K 动作菜单中可执行的动作。
enum ResultMenuAction: CaseIterable, Hashable, Sendable {
    case revealInFinder
    case copyPath
    case copyBundleID
    case openInTerminal
}

/// 选中结果的 Cmd+K 快捷操作菜单：按结果类型给出可用动作并弹出。
enum LauncherActionMenu {
    /// 当前结果可用的动作集合（纯函数，便于单测）。
    static func availableActions(for result: SearchResult) -> Set<ResultMenuAction> {
        var actions: Set<ResultMenuAction> = []
        if let url = result.url, url.isFileURL {
            actions.insert(.revealInFinder)
            actions.insert(.copyPath)
        }
        if case .application(let app) = result, app.bundleIdentifier != nil {
            actions.insert(.copyBundleID)
        }
        if result.terminalDirectory != nil {
            actions.insert(.openInTerminal)
        }
        return actions
    }

    /// 在指定视图坐标系的锚点处弹出菜单（同步阻塞直到菜单关闭）。
    static func popUp(
        for result: SearchResult,
        in view: NSView,
        at anchor: NSPoint,
        target: ResultMenuTarget
    ) {
        let available = availableActions(for: result)
        let menu = NSMenu()
        for action in ResultMenuAction.allCases where available.contains(action) {
            menu.addItem(item(for: action, target: target))
        }
        menu.popUp(positioning: nil, at: anchor, in: view)
    }

    private static func item(for action: ResultMenuAction, target: ResultMenuTarget) -> NSMenuItem {
        let item: NSMenuItem
        switch action {
        case .revealInFinder:
            item = NSMenuItem(
                title: "在 Finder 中显示",
                action: #selector(ResultMenuTarget.revealInFinder),
                keyEquivalent: ""
            )
            item.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
        case .copyPath:
            item = NSMenuItem(
                title: "复制路径",
                action: #selector(ResultMenuTarget.copyPath),
                keyEquivalent: ""
            )
            item.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: nil)
        case .copyBundleID:
            item = NSMenuItem(
                title: "复制 Bundle ID",
                action: #selector(ResultMenuTarget.copyBundleID),
                keyEquivalent: ""
            )
            item.image = NSImage(systemSymbolName: "number", accessibilityDescription: nil)
        case .openInTerminal:
            item = NSMenuItem(
                title: "在终端中打开",
                action: #selector(ResultMenuTarget.openInTerminal),
                keyEquivalent: ""
            )
            item.image = NSImage(systemSymbolName: "terminal", accessibilityDescription: nil)
        }
        item.target = target
        return item
    }
}

/// 菜单动作转发目标。NSMenuItem 只接受 NSObject 目标，
/// 而 LauncherPanelController 不是 NSObject，所以由本类承接再回调度。
@MainActor
final class ResultMenuTarget: NSObject {
    var onAction: ((ResultMenuAction) -> Void)?

    @objc func revealInFinder() {
        onAction?(.revealInFinder)
    }

    @objc func copyPath() {
        onAction?(.copyPath)
    }

    @objc func copyBundleID() {
        onAction?(.copyBundleID)
    }

    @objc func openInTerminal() {
        onAction?(.openInTerminal)
    }
}
