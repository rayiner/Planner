import AppKit

/// The reading pane: one message's envelope, body, and the actions that turn it
/// into Planner data.
///
/// A placeholder in the mode-switch PR.
final class MailReaderViewController: NSViewController {
    let persistence: PersistenceController
    let model: ModelController
    let selection: SelectionModel
    let mail: MailCoordinator

    init(
        persistence: PersistenceController,
        model: ModelController,
        selection: SelectionModel,
        mail: MailCoordinator
    ) {
        self.persistence = persistence
        self.model = model
        self.selection = selection
        self.mail = mail
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        view = NSView()
    }
}
