import AppKit
import SwiftUI

@MainActor
struct LauncherResultsList: NSViewRepresentable {
    let apps: [AppDescriptor]
    let selectedIndex: Int
    let resetRequest: Int
    let iconProvider: any ApplicationIconProviding
    let onLaunch: (AppDescriptor) -> Void

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
        scrollView.contentInsets = NSEdgeInsets(
            top: LauncherLayout.listVerticalPadding,
            left: 0,
            bottom: LauncherLayout.listVerticalPadding,
            right: 0
        )
        scrollView.documentView = tableView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let tableView = scrollView.documentView as? NSTableView else { return }

        let coordinator = context.coordinator
        let appsChanged = coordinator.apps != apps
        let selectionChanged = coordinator.selectedIndex != selectedIndex
        let shouldResetScroll = coordinator.resetRequest != resetRequest

        // The parent re-renders on every animation frame (it observes the panel
        // geometry), so skip all AppKit work when nothing actually changed.
        guard appsChanged || selectionChanged || shouldResetScroll else { return }

        coordinator.parent = self
        coordinator.apps = apps
        coordinator.selectedIndex = selectedIndex
        coordinator.resetRequest = resetRequest

        if appsChanged {
            tableView.reloadData()
        }

        guard apps.indices.contains(selectedIndex) else {
            tableView.deselectAll(nil)
            return
        }

        tableView.selectRowIndexes(IndexSet(integer: selectedIndex), byExtendingSelection: false)
        coordinator.refreshSelectionIndicators(in: tableView)

        if shouldResetScroll || appsChanged {
            tableView.scrollRowToVisible(0)
        } else if selectionChanged {
            tableView.scrollRowToVisible(selectedIndex)
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        static let columnIdentifier = NSUserInterfaceItemIdentifier("LauncherResultsColumn")
        static let cellIdentifier = NSUserInterfaceItemIdentifier("LauncherResultCell")

        var parent: LauncherResultsList
        var apps: [AppDescriptor] = []
        var selectedIndex = -1
        var resetRequest = -1

        init(parent: LauncherResultsList) {
            self.parent = parent
        }

        func numberOfRows(in tableView: NSTableView) -> Int {
            apps.count
        }

        func tableView(
            _ tableView: NSTableView,
            viewFor tableColumn: NSTableColumn?,
            row: Int
        ) -> NSView? {
            guard apps.indices.contains(row) else { return nil }

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

            let app = apps[row]
            cell.configure(
                name: app.name,
                icon: parent.iconProvider.icon(for: app.url),
                isSelected: row == selectedIndex
            )
            return cell
        }

        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            LauncherResultRowView()
        }

        func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
            true
        }

        @objc func tableViewClicked(_ sender: NSTableView) {
            let clickedRow = sender.clickedRow
            guard clickedRow >= 0 else { return }
            launch(row: clickedRow)
        }

        func launch(row: Int) {
            guard apps.indices.contains(row) else { return }
            parent.onLaunch(apps[row])
        }

        func refreshSelectionIndicators(in tableView: NSTableView) {
            let visibleRows = tableView.rows(in: tableView.visibleRect)
            guard visibleRows.location != NSNotFound else { return }

            for row in visibleRows.location..<NSMaxRange(visibleRows) {
                guard let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false)
                    as? LauncherResultCellView else {
                    continue
                }
                cell.setSelected(row == selectedIndex)
            }
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
    private let returnBadge = LauncherReturnBadge()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        appIconView.imageScaling = .scaleProportionallyUpOrDown
        appIconView.translatesAutoresizingMaskIntoConstraints = false

        nameLabel.font = .systemFont(ofSize: 17, weight: .regular)
        nameLabel.textColor = .labelColor
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.maximumNumberOfLines = 1

        addSubview(appIconView)
        addSubview(nameLabel)
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
        nameLabel.frame = NSRect(
            x: labelX,
            y: (bounds.height - 22) / 2,
            width: max(0, labelRight - labelX),
            height: 22
        )
    }

    func configure(name: String, icon: NSImage, isSelected: Bool) {
        nameLabel.stringValue = name
        appIconView.image = icon
        setSelected(isSelected)
    }

    func setSelected(_ isSelected: Bool) {
        returnBadge.alphaValue = isSelected ? 1 : 0
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
