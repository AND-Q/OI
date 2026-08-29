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
        tableView.intercellSpacing = NSSize(width: 0, height: 3)
        tableView.rowHeight = 48
        tableView.selectionHighlightStyle = .regular
        tableView.allowsEmptySelection = false
        tableView.allowsMultipleSelection = false
        tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        tableView.dataSource = context.coordinator
        tableView.delegate = context.coordinator
        tableView.onClickRow = { [weak coordinator = context.coordinator] row in
            coordinator?.launch(row: row)
        }

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
        scrollView.contentInsets = NSEdgeInsets(top: 10, left: 0, bottom: 10, right: 0)
        scrollView.documentView = tableView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let tableView = scrollView.documentView as? NSTableView else { return }

        let coordinator = context.coordinator
        let appsChanged = coordinator.apps != apps
        let selectionChanged = coordinator.selectedIndex != selectedIndex
        let shouldResetScroll = coordinator.resetRequest != resetRequest

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
            false
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
    var onClickRow: ((Int) -> Void)?

    override var acceptsFirstResponder: Bool { false }

    override func mouseDown(with event: NSEvent) {
        let clickedRow = row(at: convert(event.locationInWindow, from: nil))
        guard clickedRow >= 0 else {
            super.mouseDown(with: event)
            return
        }

        onClickRow?(clickedRow)
    }
}

private final class LauncherResultRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        guard selectionHighlightStyle != .none else { return }

        NSColor.controlAccentColor.withAlphaComponent(0.18).setFill()
        NSBezierPath(
            roundedRect: bounds.insetBy(dx: 10, dy: 0),
            xRadius: 8,
            yRadius: 8
        ).fill()
    }
}

private final class LauncherResultCellView: NSTableCellView {
    private let appIconView = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let returnImageView = NSImageView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        appIconView.imageScaling = .scaleProportionallyUpOrDown
        appIconView.wantsLayer = true
        appIconView.layer?.cornerRadius = 7
        appIconView.layer?.masksToBounds = true

        nameLabel.font = .systemFont(ofSize: 16)
        nameLabel.textColor = .labelColor
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.maximumNumberOfLines = 1

        let symbolConfiguration = NSImage.SymbolConfiguration(
            pointSize: 13,
            weight: .semibold
        )
        returnImageView.image = NSImage(
            systemSymbolName: "return",
            accessibilityDescription: "打开"
        )?.withSymbolConfiguration(symbolConfiguration)
        returnImageView.contentTintColor = .secondaryLabelColor
        returnImageView.imageScaling = .scaleProportionallyDown

        addSubview(appIconView)
        addSubview(nameLabel)
        addSubview(returnImageView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()

        let iconSize: CGFloat = 34
        let horizontalInset: CGFloat = 20
        let accessorySize: CGFloat = 18
        let spacing: CGFloat = 12

        appIconView.frame = NSRect(
            x: horizontalInset,
            y: (bounds.height - iconSize) / 2,
            width: iconSize,
            height: iconSize
        )
        returnImageView.frame = NSRect(
            x: bounds.width - horizontalInset - accessorySize,
            y: (bounds.height - accessorySize) / 2,
            width: accessorySize,
            height: accessorySize
        )

        let labelX = appIconView.frame.maxX + spacing
        let labelRight = returnImageView.frame.minX - spacing
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
        returnImageView.alphaValue = isSelected ? 1 : 0
    }
}
