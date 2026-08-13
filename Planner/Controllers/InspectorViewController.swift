import AppKit

final class InspectorViewController: NSViewController {
    private let titleLabel = NSTextField(labelWithString: "Select a task")
    private let completedCheckbox = NSButton(checkboxWithTitle: "Completed", target: nil, action: nil)
    private let hasDeadlineCheckbox = NSButton(checkboxWithTitle: "Has deadline", target: nil, action: nil)
    private let datePicker = NSDatePicker()
    private let deadlineRow = NSStackView()
    private let notesLabel = NSTextField(labelWithString: "Notes")
    private let notesScrollView = NSTextView.scrollableTextView()

    override func loadView() {
        view = NSView()
        configureControls()

        deadlineRow.orientation = .horizontal
        deadlineRow.alignment = .centerY
        deadlineRow.spacing = 8
        deadlineRow.addArrangedSubview(hasDeadlineCheckbox)
        deadlineRow.addArrangedSubview(datePicker)
        deadlineRow.isHidden = true

        let stack = NSStackView(views: [
            titleLabel,
            completedCheckbox,
            deadlineRow,
            notesLabel,
            notesScrollView,
        ])
        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)

        notesScrollView.setContentHuggingPriority(.defaultLow, for: .vertical)
        notesScrollView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.topAnchor),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    private func configureControls() {
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        titleLabel.cell?.truncatesLastVisibleLine = true
        titleLabel.font = .preferredFont(forTextStyle: .headline)
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titleLabel.isEnabled = false

        completedCheckbox.isEnabled = false
        completedCheckbox.isHidden = true

        hasDeadlineCheckbox.isEnabled = false
        hasDeadlineCheckbox.isHidden = true

        datePicker.datePickerStyle = .textFieldAndStepper
        datePicker.datePickerMode = .single
        datePicker.datePickerElements = .yearMonthDay
        datePicker.isEnabled = false
        datePicker.isHidden = true

        notesLabel.isHidden = true

        notesScrollView.borderType = .bezelBorder
        notesScrollView.hasVerticalScroller = true
        notesScrollView.autohidesScrollers = true
        notesScrollView.isHidden = true

        let notesTextView = notesScrollView.documentView as? NSTextView
        notesTextView?.isRichText = false
        notesTextView?.usesFontPanel = false
        notesTextView?.font = .preferredFont(forTextStyle: .body)
        notesTextView?.isEditable = false
        notesTextView?.isSelectable = false
    }
}
