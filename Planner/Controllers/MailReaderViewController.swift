import AppKit
import CoreData

/// The reading pane: one message's envelope, body, and the actions that turn it
/// into Planner data.
///
/// The envelope is drawn the moment a row is selected; the body arrives later,
/// because the M0 spike put it behind a per-message fetch. That split is
/// visible in the layout — header and banner are immediate, the body area
/// carries its own spinner — and it is what keeps selecting a message feeling
/// instant on a mailbox where a sweep costs ten seconds.
///
/// **Nothing here writes to Outlook.** No reply, no forward, no mark-read: the
/// only actions are Save, which copies into Planner's own store, and Open in
/// Outlook, which is the user asking for the original.
final class MailReaderViewController: NSViewController {
    let persistence: PersistenceController
    let model: ModelController
    let selection: SelectionModel
    let mail: MailCoordinator

    private let calendar: Calendar
    private let now: () -> Date

    private let subjectField = NSTextField(labelWithString: "")
    private let senderField = NSTextField(labelWithString: "")
    private let recipientsField = NSTextField(labelWithString: "")
    private let dateField = NSTextField(labelWithString: "")
    private let attachmentsField = NSTextField(labelWithString: "")
    private let expiryBanner = NSTextField(labelWithString: "")
    private let conversationField = NSTextField(labelWithString: "")
    private let bodyView = NSTextView()
    private let bodyScrollView = NSScrollView()
    private let bodySpinner = NSProgressIndicator()
    private let bodyStatusField = NSTextField(labelWithString: "")
    private let headerStack = NSStackView()
    private let emptyStateLabel = NSTextField(labelWithString: MailLabels.noMessageSelected)

    private let saveButton = NSPopUpButton(frame: .zero, pullsDown: true)
    private let newTaskButton = NSButton()
    private let openInOutlookButton = NSButton()
    private let actionBar = NSStackView()

    /// What the reader is currently showing, so a late body can be matched
    /// against it rather than painted over whatever is on screen now.
    private var displayedMessageID: Int64?
    private var isBodyLoading = false

    init(
        persistence: PersistenceController,
        model: ModelController,
        selection: SelectionModel,
        mail: MailCoordinator,
        calendar: Calendar = .current,
        now: @escaping () -> Date = { Date() }
    ) {
        self.persistence = persistence
        self.model = model
        self.selection = selection
        self.mail = mail
        self.calendar = calendar
        self.now = now
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override func loadView() {
        let root = NSView()
        buildHeader(in: root)
        buildBody(in: root)
        buildActionBar(in: root)

        emptyStateLabel.font = .systemFont(ofSize: 13)
        emptyStateLabel.textColor = .secondaryLabelColor
        emptyStateLabel.alignment = .center
        emptyStateLabel.refusesFirstResponder = true
        emptyStateLabel.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(emptyStateLabel)

        NSLayoutConstraint.activate([
            headerStack.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor, constant: 16),
            headerStack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            headerStack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),

            bodyScrollView.topAnchor.constraint(equalTo: headerStack.bottomAnchor, constant: 12),
            bodyScrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            bodyScrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            bodyScrollView.bottomAnchor.constraint(equalTo: actionBar.topAnchor, constant: -10),

            bodySpinner.centerXAnchor.constraint(equalTo: bodyScrollView.centerXAnchor),
            bodySpinner.centerYAnchor.constraint(equalTo: bodyScrollView.centerYAnchor, constant: -14),
            bodyStatusField.topAnchor.constraint(equalTo: bodySpinner.bottomAnchor, constant: 10),
            bodyStatusField.centerXAnchor.constraint(equalTo: bodyScrollView.centerXAnchor),
            bodyStatusField.leadingAnchor.constraint(greaterThanOrEqualTo: root.leadingAnchor, constant: 24),
            bodyStatusField.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -24),

            actionBar.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            actionBar.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -20),
            actionBar.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -14),

            emptyStateLabel.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            emptyStateLabel.centerYAnchor.constraint(equalTo: root.centerYAnchor),
        ])
        view = root
    }

    private func buildHeader(in root: NSView) {
        subjectField.font = .systemFont(ofSize: 17, weight: .semibold)
        subjectField.lineBreakMode = .byWordWrapping
        subjectField.maximumNumberOfLines = 3
        subjectField.isSelectable = true

        for field in [senderField, recipientsField, dateField, attachmentsField] {
            field.font = .systemFont(ofSize: 12)
            field.textColor = .secondaryLabelColor
            field.lineBreakMode = .byTruncatingTail
            field.isSelectable = true
        }
        senderField.textColor = .labelColor

        attachmentsField.textColor = .secondaryLabelColor

        expiryBanner.font = .systemFont(ofSize: 11, weight: .medium)
        expiryBanner.textColor = .secondaryLabelColor
        expiryBanner.lineBreakMode = .byWordWrapping
        expiryBanner.maximumNumberOfLines = 2

        conversationField.font = .systemFont(ofSize: 11)
        conversationField.textColor = .secondaryLabelColor

        headerStack.orientation = .vertical
        headerStack.alignment = .leading
        headerStack.spacing = 3
        headerStack.detachesHiddenViews = true
        headerStack.translatesAutoresizingMaskIntoConstraints = false
        for view in [subjectField, senderField, recipientsField, dateField,
                     attachmentsField, conversationField, expiryBanner] {
            headerStack.addArrangedSubview(view)
            view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        }
        root.addSubview(headerStack)
    }

    private func buildBody(in root: NSView) {
        // Plain text, never HTML: message bodies are untrusted remote content,
        // and a reading pane is not a browser. `plain text content` is what the
        // source asks Outlook for.
        bodyView.isEditable = false
        bodyView.isSelectable = true
        bodyView.drawsBackground = false
        bodyView.font = .systemFont(ofSize: 13)
        bodyView.textContainerInset = NSSize(width: 4, height: 4)
        bodyView.isAutomaticLinkDetectionEnabled = false
        bodyView.textContainer?.widthTracksTextView = true

        bodyScrollView.documentView = bodyView
        bodyScrollView.hasVerticalScroller = true
        bodyScrollView.autohidesScrollers = true
        bodyScrollView.borderType = .noBorder
        bodyScrollView.drawsBackground = false
        bodyScrollView.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(bodyScrollView)

        bodySpinner.style = .spinning
        bodySpinner.controlSize = .small
        bodySpinner.isDisplayedWhenStopped = false
        bodySpinner.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(bodySpinner)

        bodyStatusField.font = .systemFont(ofSize: 12)
        bodyStatusField.textColor = .secondaryLabelColor
        bodyStatusField.alignment = .center
        bodyStatusField.maximumNumberOfLines = 0
        bodyStatusField.lineBreakMode = .byWordWrapping
        bodyStatusField.refusesFirstResponder = true
        bodyStatusField.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(bodyStatusField)
    }

    private func buildActionBar(in root: NSView) {
        saveButton.bezelStyle = .rounded
        saveButton.title = "Save to Folder"
        saveButton.target = self
        saveButton.action = #selector(saveButtonClicked(_:))

        newTaskButton.bezelStyle = .rounded
        newTaskButton.title = "New Task"
        newTaskButton.target = self
        newTaskButton.action = #selector(newTaskFromMessage(_:))

        openInOutlookButton.bezelStyle = .rounded
        openInOutlookButton.title = "Open in Outlook"
        openInOutlookButton.target = self
        openInOutlookButton.action = #selector(openInOutlook(_:))

        actionBar.orientation = .horizontal
        actionBar.alignment = .centerY
        actionBar.spacing = 8
        actionBar.detachesHiddenViews = true
        actionBar.translatesAutoresizingMaskIntoConstraints = false
        for button in [saveButton, newTaskButton, openInOutlookButton] {
            actionBar.addArrangedSubview(button)
        }
        root.addSubview(actionBar)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        startObserving()
        rebind()
    }

    private func startObserving() {
        let center = NotificationCenter.default
        center.addObserver(
            self,
            selector: #selector(plannerSelectionDidChange(_:)),
            name: .plannerSelectionDidChange,
            object: selection
        )
        center.addObserver(
            self,
            selector: #selector(mailDetailDidChange(_:)),
            name: .plannerMailDetailDidChange,
            object: mail
        )
        center.addObserver(
            self,
            selector: #selector(mailDidChange(_:)),
            name: .plannerMailDidChange,
            object: mail
        )
        center.addObserver(
            self,
            selector: #selector(contextDidSave(_:)),
            name: .NSManagedObjectContextDidSave,
            object: persistence.viewContext
        )
    }

    @objc private func plannerSelectionDidChange(_ notification: Notification) {
        let fields = notification.userInfo?[SelectionUserInfoKey.changedFields] as? Set<String> ?? []
        guard fields.contains(SelectionField.message.rawValue)
            || fields.contains(SelectionField.mailbox.rawValue) else { return }
        rebind()
    }

    /// A refresh can retire the message the reader is showing.
    @objc private func mailDidChange(_ notification: Notification) { rebind() }
    @objc private func contextDidSave(_ notification: Notification) { updateActionBar() }

    @objc private func mailDetailDidChange(_ notification: Notification) {
        let id = notification.userInfo?[MailChangeUserInfoKey.messageID] as? Int64
        // A body that arrives for a message the user has already moved on from
        // must not paint over the one on screen.
        guard id == displayedMessageID else { return }
        updateBody()
    }

    // MARK: - Binding

    func rebind() {
        guard case let .recent(id)? = selection.message, let message = mail.message(id: id) else {
            showEmptyState()
            return
        }
        displayedMessageID = id
        emptyStateLabel.isHidden = true
        headerStack.isHidden = false
        bodyScrollView.isHidden = false
        actionBar.isHidden = false

        subjectField.stringValue = message.subject.isEmpty ? "(No subject)" : message.subject
        senderField.stringValue = MailLabels.senderLine(
            name: message.senderName,
            address: message.senderAddress
        )
        dateField.stringValue = MailLabels.readerTimestamp(for: message.receivedAt, calendar: calendar)
        conversationField.isHidden = true

        updateExpiry(for: message)
        updateRecipientsAndAttachments()
        // The one place a fetch is requested: opening a message is what asks
        // for its body, and a failed one is retried by re-selecting it.
        _ = mail.detailState(for: id)
        updateBody()
        updateActionBar()
    }

    private func showEmptyState() {
        displayedMessageID = nil
        emptyStateLabel.isHidden = false
        headerStack.isHidden = true
        bodyScrollView.isHidden = true
        actionBar.isHidden = true
        setBodyLoading(false)
        bodyStatusField.isHidden = true
    }

    private func updateExpiry(for message: MailMessage) {
        guard let expiry = mail.expiryDay(for: message),
              MailLabels.shouldShowExpiry(expiry: expiry, now: now(), calendar: calendar)
        else {
            expiryBanner.isHidden = true
            return
        }
        expiryBanner.stringValue = MailLabels.expiryNotice(
            expiry: expiry,
            now: now(),
            calendar: calendar
        )
        expiryBanner.isHidden = false
    }

    /// Recipients and attachment names live in the headers, which arrive with
    /// the body — so these two lines appear a beat after the rest.
    private func updateRecipientsAndAttachments() {
        let detail = displayedMessageID.flatMap { mail.cachedDetail(for: $0) }
        if let line = MailLabels.recipientsLine(detail?.recipients) {
            recipientsField.stringValue = line
            recipientsField.isHidden = false
        } else {
            recipientsField.isHidden = true
        }

        let names = detail?.attachmentNames?
            .components(separatedBy: "\n")
            .filter { !$0.isEmpty } ?? []
        if let line = MailLabels.attachmentsLine(names: names) {
            attachmentsField.stringValue = "📎 \(line)"
            attachmentsField.isHidden = false
        } else {
            attachmentsField.isHidden = true
        }
    }

    /// Draws whatever the coordinator currently has, **without** asking it to
    /// fetch: `detailState(for:)` retries a failed body, so reading it here
    /// would restart the fetch and the failure would never be shown. The one
    /// request is made in `rebind`, where a message is genuinely being opened.
    private func updateBody() {
        guard let id = displayedMessageID else { return }
        switch mail.detailState(for: id, load: false) {
        case .loaded(let detail):
            setBodyLoading(false)
            bodyStatusField.isHidden = true
            bodyScrollView.isHidden = false
            bodyView.string = detail.body
            bodyView.scroll(.zero)
            updateRecipientsAndAttachments()
        case .loading, .idle:
            // Keep whatever is already on screen while a body loads: blanking
            // it makes re-selecting a message you have already read flicker.
            setBodyLoading(true)
            bodyStatusField.isHidden = true
            if mail.cachedDetail(for: id) == nil { bodyView.string = "" }
        case .failed(let message):
            setBodyLoading(false)
            bodyStatusField.stringValue = message
            bodyStatusField.isHidden = false
            bodyView.string = ""
        }
    }

    /// `NSProgressIndicator` manages its own visibility when stopped, but not
    /// synchronously, so the flag is tracked rather than inferred.
    private func setBodyLoading(_ loading: Bool) {
        isBodyLoading = loading
        bodySpinner.isHidden = !loading
        if loading { bodySpinner.startAnimation(nil) } else { bodySpinner.stopAnimation(nil) }
    }

    private func updateActionBar() {
        // Saving and task-creation land in later PRs; the buttons are drawn now
        // so the pane's proportions are settled, and disabled so they cannot
        // lie about what they do.
        saveButton.isEnabled = false
        newTaskButton.isEnabled = false
        openInOutlookButton.isEnabled = displayedMessageID != nil
    }

    // MARK: - Actions

    @objc private func saveButtonClicked(_ sender: Any?) {}
    @objc private func newTaskFromMessage(_ sender: Any?) {}

    @objc private func openInOutlook(_ sender: Any?) {
        guard let id = displayedMessageID else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                try await mail.reveal(messageID: id)
            } catch {
                presentReadOnly(error)
            }
        }
    }

    private func presentReadOnly(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        alert.informativeText = (error as? LocalizedError)?.recoverySuggestion ?? ""
        alert.alertStyle = .warning
        if let window = view.window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }
}

extension MailReaderViewController {
    var test_isEmptyStateVisible: Bool { !emptyStateLabel.isHidden }
    var test_subject: String { subjectField.stringValue }
    var test_sender: String { senderField.stringValue }
    var test_date: String { dateField.stringValue }
    var test_body: String { bodyView.string }
    var test_expiryText: String? { expiryBanner.isHidden ? nil : expiryBanner.stringValue }
    var test_bodyStatus: String? { bodyStatusField.isHidden ? nil : bodyStatusField.stringValue }
    var test_isBodyLoading: Bool { isBodyLoading }
    var test_recipients: String? { recipientsField.isHidden ? nil : recipientsField.stringValue }
    var test_attachments: String? { attachmentsField.isHidden ? nil : attachmentsField.stringValue }
    var test_displayedMessageID: Int64? { displayedMessageID }
}
