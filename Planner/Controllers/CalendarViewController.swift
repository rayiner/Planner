import AppKit

final class CalendarViewController: NSViewController {
    let persistence: PersistenceController
    let model: ModelController
    let selection: SelectionModel

    init(
        persistence: PersistenceController,
        model: ModelController,
        selection: SelectionModel
    ) {
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
        view = NSView()

        let formatter = DateFormatter()
        formatter.calendar = Calendar.current
        formatter.setLocalizedDateFormatFromTemplate("MMMM yyyy")

        let label = NSTextField(labelWithString: formatter.string(from: Date()))
        label.font = .preferredFont(forTextStyle: .title2)
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)

        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            label.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
        ])
    }
}
