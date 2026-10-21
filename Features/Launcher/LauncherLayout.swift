import Foundation

/// Layout metrics calibrated against the macOS 27 Spotlight reference images.
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
    /// Minimum panel expansion reserved for the floating action sheet.
    static let actionSheetMinHeight: CGFloat = 185
    /// Floating action sheet width and its insets from the panel's bottom-trailing corner.
    static let actionSheetWidth: CGFloat = 250
    static let actionSheetTrailingInset: CGFloat = 16
    static let actionSheetBottomInset: CGFloat = 12
    /// Launch-failure banner above the results list, including its top inset;
    /// reserved in the expanded height so it never squeezes the rows.
    static let launchErrorBannerHeight: CGFloat = 32
    /// Quick AI answer area (answer plus footer), fixed so streaming never resizes the window.
    static let quickAIHeight: CGFloat = 400
    static let quickAIFooterHeight: CGFloat = 32

    /// What the expanded area below the search field shows.
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
