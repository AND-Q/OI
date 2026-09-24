import AppKit
import SwiftUI

@MainActor
struct LauncherResultsList: NSViewRepresentable {
    let rows: [LauncherRow]
    let selectedRowIndex: Int
    let resetRequest: Int
    let iconProvider: any ApplicationIconProviding
    let onOpen: (SearchResult) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let tableView = LauncherTableView()
        tableView.backgroundColor = .clear
        tableView.headerView = nil
        tableView.style = .fullWidth
        tableView.intercellSpacing = NSSize(width: 0, height: 0)
        tableView.rowHeight = LauncherLayout.rowHeight
        tableView.selectionHighlightStyle = .regular
        tableView.allowsEmptySelection = false
        tableView.allowsMultipleSelection = false
        tableView.floatsGroupRows = false
        tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        tableView.dataSource = context.coordinator
        tableView.delegate = context.coordinator
        tableView.target = context.coordinator
        tableView.action = #selector(Coordinator.tableViewClicked(_:))

        let column = NSTableColumn(identifier: Coordinator.columnIdentifier)
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)

        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.documentView = tableView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let tableView = scrollView.documentView as? NSTableView else { return }

        let coordinator = context.coordinator
        let rowsChanged = coordinator.rows != rows
        let selectionChanged = coordinator.selectedRowIndex != selectedRowIndex
        let shouldResetScroll = coordinator.resetRequest != resetRequest

        // The parent re-renders on every animation frame (it observes the panel
        // geometry), so skip all AppKit work when nothing actually changed.
        guard rowsChanged || selectionChanged || shouldResetScroll else { return }

        coordinator.parent = self
        coordinator.rows = rows
        coordinator.selectedRowIndex = selectedRowIndex
        coordinator.resetRequest = resetRequest

        if rowsChanged {
            tableView.reloadData()
        }

        guard rows.indices.contains(selectedRowIndex) else {
            tableView.deselectAll(nil)
            return
        }

        tableView.selectRowIndexes(IndexSet(integer: selectedRowIndex), byExtendingSelection: false)
        coordinator.refreshSelectionIndicators(in: tableView)

        // Query changes come with a reset request; file results arriving later
        // must not yank the list away from the row the user has moved to.
        if shouldResetScroll {
            tableView.scrollRowToVisible(0)
        } else {
            tableView.scrollRowToVisible(selectedRowIndex)
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        static let columnIdentifier = NSUserInterfaceItemIdentifier("LauncherResultsColumn")
        static let cellIdentifier = NSUserInterfaceItemIdentifier("LauncherResultCell")
        static let headerIdentifier = NSUserInterfaceItemIdentifier("LauncherSectionHeaderCell")

        var parent: LauncherResultsList
        var rows: [LauncherRow] = []
        var selectedRowIndex = -1
        var resetRequest = -1

        init(parent: LauncherResultsList) {
            self.parent = parent
        }

        func numberOfRows(in tableView: NSTableView) -> Int {
            rows.count
        }

        func tableView(
            _ tableView: NSTableView,
            viewFor tableColumn: NSTableColumn?,
            row: Int
        ) -> NSView? {
            guard rows.indices.contains(row) else { return nil }

            switch rows[row] {
            case .sectionHeader(let title):
                let cell: LauncherSectionHeaderView
                if let reusedCell = tableView.makeView(
                    withIdentifier: Self.headerIdentifier,
                    owner: nil
                ) as? LauncherSectionHeaderView {
                    cell = reusedCell
                } else {
                    cell = LauncherSectionHeaderView()
                    cell.identifier = Self.headerIdentifier
                }
                cell.configure(title: title)
                return cell

            case .result(let result):
                let cell: LauncherResultCellView
                if let reusedCell = tableView.makeView(
                    withIdentifier: Self.cellIdentifier,
                    owner: nil
                ) as? LauncherResultCellView {
                    cell = reusedCell
                } else {
                    cell = LauncherResultCellView()
                    cell.identifier = Self.cellIdentifier
                }

                cell.configure(
                    name: result.name,
                    subtitle: Self.subtitle(for: result),
                    icon: Self.icon(for: result, provider: parent.iconProvider),
                    isSelected: row == selectedRowIndex,
                    isQuickQuery: result.isQuickQuery
                )
                return cell
            }
        }

        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            LauncherResultRowView()
        }

        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
            guard rows.indices.contains(row), case .sectionHeader = rows[row] else {
                return LauncherLayout.rowHeight
            }
            return LauncherLayout.sectionHeaderHeight
        }

        func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
            guard rows.indices.contains(row), case .sectionHeader = rows[row] else { return false }
            return true
        }

        func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
            guard rows.indices.contains(row), case .result = rows[row] else { return false }
            return true
        }

        @objc func tableViewClicked(_ sender: NSTableView) {
            let clickedRow = sender.clickedRow
            guard clickedRow >= 0 else { return }
            open(row: clickedRow)
        }

        func open(row: Int) {
            guard rows.indices.contains(row), case .result(let result) = rows[row] else { return }
            parent.onOpen(result)
        }

        func refreshSelectionIndicators(in tableView: NSTableView) {
            let visibleRows = tableView.rows(in: tableView.visibleRect)
            guard visibleRows.location != NSNotFound else { return }

            for row in visibleRows.location..<NSMaxRange(visibleRows) {
                guard let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false)
                    as? LauncherResultCellView else {
                    continue
                }
                cell.setSelected(row == selectedRowIndex)
            }
        }

        /// Files show their parent folder with `~` abbreviation; applications show nothing.
        static func subtitle(for result: SearchResult) -> String? {
            switch result {
            case .file(let file):
                return (file.url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath
            case .quickQuery(let quickQuery):
                return quickQuery.subtitle
            case .application:
                return nil
            }
        }

        static func icon(
            for result: SearchResult,
            provider: any ApplicationIconProviding
        ) -> NSImage {
            if let url = result.url { return provider.icon(for: url) }
            guard case .quickQuery(let quickQuery) = result else { return NSImage() }
            return NSImage(systemSymbolName: quickQuery.symbolName, accessibilityDescription: nil)
                ?? NSImage()
        }
    }
}

private final class LauncherTableView: NSTableView {
    override var acceptsFirstResponder: Bool { false }
}

/// Neutral gray rounded selection matching Spotlight (never the system accent blue).
private final class LauncherResultRowView: NSTableRowView {
    override var isEmphasized: Bool {
        get { false }
        set { }
    }

    override func drawSelection(in dirtyRect: NSRect) {
        guard selectionHighlightStyle != .none else { return }

        let fill = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
            ? NSColor.unemphasizedSelectedContentBackgroundColor
            : LauncherResultRowView.selectionFill
        fill.setFill()
        NSBezierPath(
            roundedRect: bounds.insetBy(dx: 10, dy: 1.5),
            xRadius: 18,
            yRadius: 18
        ).fill()
    }

    private static let selectionFill = NSColor(name: nil) { appearance in
        appearance.isDarkMode ? NSColor.white.withAlphaComponent(0.10)
                              : NSColor.black.withAlphaComponent(0.09)
    }
}

private final class LauncherResultCellView: NSTableCellView {
    private enum Metrics {
        static let horizontalInset: CGFloat = 12
        static let iconSize: CGFloat = 44
        static let iconTextSpacing: CGFloat = 10
        static let badgeWidth: CGFloat = 28
        static let badgeHeight: CGFloat = 18
        static let badgeSpacing: CGFloat = 12
    }

    private let appIconView = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let returnBadge = LauncherReturnBadge()
    private var isQuickQuery = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        appIconView.imageScaling = .scaleProportionallyUpOrDown
        appIconView.translatesAutoresizingMaskIntoConstraints = false

        nameLabel.font = .systemFont(ofSize: 17, weight: .regular)
        nameLabel.textColor = .labelColor
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.maximumNumberOfLines = 1

        subtitleLabel.font = .systemFont(ofSize: 12, weight: .regular)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.lineBreakMode = .byTruncatingMiddle
        subtitleLabel.maximumNumberOfLines = 1

        addSubview(appIconView)
        addSubview(nameLabel)
        addSubview(subtitleLabel)
        addSubview(returnBadge)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()

        let m = Metrics.self
        appIconView.frame = NSRect(
            x: m.horizontalInset,
            y: (bounds.height - m.iconSize) / 2,
            width: m.iconSize,
            height: m.iconSize
        )
        returnBadge.frame = NSRect(
            x: bounds.width - m.horizontalInset - m.badgeWidth,
            y: (bounds.height - m.badgeHeight) / 2,
            width: m.badgeWidth,
            height: m.badgeHeight
        )

        let labelX = appIconView.frame.maxX + m.iconTextSpacing
        let labelRight = returnBadge.frame.minX - m.badgeSpacing
        let labelWidth = max(0, labelRight - labelX)
        let nameHeight: CGFloat = isQuickQuery ? 28 : 22
        if subtitleLabel.isHidden {
            nameLabel.frame = NSRect(
                x: labelX,
                y: (bounds.height - nameHeight) / 2,
                width: labelWidth,
                height: nameHeight
            )
        } else {
            // Two lines stacked and centred as a block (flipped-off coordinates: y grows upward).
            let blockHeight = nameHeight + 16
            let blockY = (bounds.height - blockHeight) / 2
            subtitleLabel.frame = NSRect(x: labelX, y: blockY, width: labelWidth, height: 16)
            nameLabel.frame = NSRect(x: labelX, y: blockY + 16, width: labelWidth, height: nameHeight)
        }
    }

    func configure(
        name: String,
        subtitle: String?,
        icon: NSImage,
        isSelected: Bool,
        isQuickQuery: Bool = false
    ) {
        nameLabel.stringValue = name
        subtitleLabel.stringValue = subtitle ?? ""
        subtitleLabel.isHidden = subtitle == nil
        self.isQuickQuery = isQuickQuery
        nameLabel.font = isQuickQuery
            ? .systemFont(ofSize: 23, weight: .medium)
            : .systemFont(ofSize: 17, weight: .regular)
        appIconView.image = icon
        setSelected(isSelected)
        needsLayout = true
    }

    func setSelected(_ isSelected: Bool) {
        returnBadge.alphaValue = isSelected ? 1 : 0
    }
}

/// Non-selectable group row separating the file section from the applications.
private final class LauncherSectionHeaderView: NSTableCellView {
    private let titleLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        titleLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        titleLabel.textColor = .secondaryLabelColor
        titleLabel.maximumNumberOfLines = 1
        addSubview(titleLabel)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        titleLabel.frame = NSRect(
            x: 22,
            y: (bounds.height - 14) / 2,
            width: max(0, bounds.width - 44),
            height: 14
        )
    }

    func configure(title: String) {
        titleLabel.stringValue = title
    }
}

/// Small keycap-styled glass badge containing the return glyph, shown on the selected row.
private final class LauncherReturnBadge: NSGlassEffectView {
    private let glyphView = NSImageView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        style = .regular
        cornerRadius = 5

        let symbolConfiguration = NSImage.SymbolConfiguration(
            pointSize: 14,
            weight: .semibold
        )
        glyphView.image = NSImage(
            systemSymbolName: "return",
            accessibilityDescription: "打开"
        )?.withSymbolConfiguration(symbolConfiguration)
        glyphView.contentTintColor = .secondaryLabelColor
        glyphView.imageScaling = .scaleProportionallyDown
        contentView = glyphView
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        glyphView.frame = bounds.insetBy(dx: 6, dy: 3.5)
    }
}

private extension NSAppearance {
    var isDarkMode: Bool {
        bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }
}
