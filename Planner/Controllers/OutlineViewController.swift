import AppKit

final class OutlineViewController: NSViewController {
    private let outlineView = NSOutlineView()

    override func loadView() {
        let scrollView = NSScrollView()
        scrollView.documentView = outlineView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        view = scrollView
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        outlineView.style = .sourceList
        outlineView.selectionHighlightStyle = .sourceList
        outlineView.rowHeight = 22
        outlineView.headerView = nil
        outlineView.usesAlternatingRowBackgroundColors = false
        outlineView.indentationPerLevel = 16
        outlineView.allowsMultipleSelection = false
        outlineView.allowsEmptySelection = true
        outlineView.floatsGroupRows = false
        outlineView.focusRingType = .none
        outlineView.backgroundColor = .clear

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("Title"))
        column.title = "Title"
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
    }
}
