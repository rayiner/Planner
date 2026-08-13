import AppKit

final class PlannerOutlineView: NSOutlineView {
    override func menu(for event: NSEvent) -> NSMenu? {
        let location = convert(event.locationInWindow, from: nil)
        let clicked = row(at: location)
        if clicked >= 0 {
            selectRowIndexes(IndexSet(integer: clicked), byExtendingSelection: false)
        }
        return nil
    }
}
