import Foundation

/// 启动器面板的尺寸参数，按 macOS 27 聚焦搜索的参考截图校准。
enum LauncherLayout {
    static let width: CGFloat = 640
    static let searchHeight: CGFloat = 57
    static let rowHeight: CGFloat = 56
    static let sectionHeaderHeight: CGFloat = 24
    static let listVerticalPadding: CGFloat = 8
    static let statusHeight: CGFloat = 205
    static let maximumVisibleRows = 7

    static let compactCornerRadius: CGFloat = searchHeight / 2
    static let expandedCornerRadius: CGFloat = 32
    /// 为浮动的操作卡片预留的最小展开高度。
    static let actionSheetMinHeight: CGFloat = 185
    /// 浮动操作卡片的宽度，以及它与面板右下角的间距。
    static let actionSheetWidth: CGFloat = 250
    static let actionSheetTrailingInset: CGFloat = 16
    static let actionSheetBottomInset: CGFloat = 12
    /// 结果列表上方失败横幅的高度（含顶部间距），计入展开高度，不挤占结果行。
    static let launchErrorBannerHeight: CGFloat = 32
    /// Quick AI 回答区（对话、追问框与页脚）的固定高度，流式输出期间窗口不随内容变化尺寸。
    static let quickAIHeight: CGFloat = 400
    /// 对话下方的追问框一行（含上下间距）与页脚的高度。
    static let quickAIComposerHeight: CGFloat = 52
    static let quickAIFooterHeight: CGFloat = 28

    /// 输入框下方展开区域显示的内容。
    enum ExpandedContent: Equatable {
        case results(rowCount: Int, sectionHeaderCount: Int = 0, minHeight: CGFloat = 0, hasLaunchError: Bool = false)
        case status
        case quickAI

        var height: CGFloat {
            switch self {
            case .results(let rowCount, let sectionHeaderCount, let minHeight, let hasLaunchError):
                let contentHeight = CGFloat(max(rowCount, 0)) * LauncherLayout.rowHeight
                    + CGFloat(max(sectionHeaderCount, 0)) * LauncherLayout.sectionHeaderHeight
                    + (hasLaunchError ? LauncherLayout.launchErrorBannerHeight : 0)
                let maximumHeight = CGFloat(LauncherLayout.maximumVisibleRows) * LauncherLayout.rowHeight
                let baseHeight = LauncherLayout.listVerticalPadding * 2 + min(contentHeight, maximumHeight)
                return max(baseHeight, minHeight)
            case .status:
                return LauncherLayout.statusHeight
            case .quickAI:
                return LauncherLayout.quickAIHeight
            }
        }
    }

    static func totalHeight(isExpanded: Bool, content: ExpandedContent?) -> CGFloat {
        guard isExpanded, let content else { return searchHeight }
        return searchHeight + 1 + content.height
    }
}
