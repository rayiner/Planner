import AppKit

/// The mail sidebar: Recent Mail, then the user's folders.
///
/// A placeholder in the mode-switch PR — it exists so the shell has something
/// real to swap the outline for, and so the split geometry can be exercised
/// before any of the mail machinery lands.
final class MailboxListViewController: NSViewController {
    let persistence: PersistenceController
    let model: ModelController
    let selection: SelectionModel

    init(persistence: PersistenceController, model: ModelController, selection: SelectionModel) {
        self.persistence = persistence
        self.model = model
        self.selection = selection
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let headerLabel = NSTextField(labelWithString: "Mailboxes")
        headerLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        headerLabel.textColor = .secondaryLabelColor
        headerLabel.translatesAutoresizingMaskIntoConstraints = false

        // The sidebar split item supplies the vibrant material; a plain host
        // view lets it through instead of stacking a second effect view on it.
        let root = NSView()
        root.addSubview(headerLabel)
        view = root

        NSLayoutConstraint.activate([
            headerLabel.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor, constant: 4),
            headerLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 18),
            headerLabel.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -12),
        ])
    }
}
