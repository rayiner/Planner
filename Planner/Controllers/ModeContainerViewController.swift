import AppKit

/// Hosts one child view controller at a time, so a split view item can outlive
/// the content inside it.
///
/// The sidebar item is the one pane that survives a mode switch — the whole
/// effect the switch is going for is "the content changed", not "the layout
/// rearranged", and a sidebar that is torn down and rebuilt flickers and loses
/// its scroll position. `NSSplitViewItem.viewController` is fixed at init, so
/// the item holds this and this holds whichever sidebar the mode wants.
final class ModeContainerViewController: NSViewController {
    private(set) var current: NSViewController?

    override func loadView() {
        view = NSView()
    }

    func show(_ child: NSViewController) {
        guard current !== child else { return }
        loadViewIfNeeded()

        if let current {
            current.view.removeFromSuperview()
            current.removeFromParent()
        }

        addChild(child)
        child.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(child.view)
        NSLayoutConstraint.activate([
            child.view.topAnchor.constraint(equalTo: view.topAnchor),
            child.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            child.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            child.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        current = child
    }
}
