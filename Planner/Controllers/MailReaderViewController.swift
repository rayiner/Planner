import AppKit
import CoreData

/// The reading pane: one message's envelope and body. The actions that turn a
/// message into Planner data live in the toolbar, over this pane.
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
    /// Leading/trailing inset of the header stack; wrap width is the pane
    /// minus this on both sides.
    private static let headerInset: CGFloat = 20

    /// What the reader is currently showing, so a late body can be matched
    /// against it rather than painted over whatever is on screen now.
    private var displayedMessageID: Int64?
    private var displayedSavedUUID: UUID?
    private var isBodyLoading = false

    /// Which conversation the open message sits in, for the "message k of n"
    /// line. Supplied by the list, which is where threading is computed —
    /// the reader has no business threading a folder a second time.
    var conversationProvider: ((UUID) -> [SavedMessage])?

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

        emptyStateLabel.font = .systemFont(ofSize: 13)
        emptyStateLabel.textColor = .secondaryLabelColor
        emptyStateLabel.alignment = .center
        emptyStateLabel.refusesFirstResponder = true
        emptyStateLabel.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(emptyStateLabel)

        NSLayoutConstraint.activate([
            headerStack.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor, constant: 16),
            headerStack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: Self.headerInset),
            headerStack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -Self.headerInset),

            bodyScrollView.topAnchor.constraint(equalTo: headerStack.bottomAnchor, constant: 12),
            bodyScrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            bodyScrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            bodyScrollView.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),

            bodySpinner.centerXAnchor.constraint(equalTo: bodyScrollView.centerXAnchor),
            bodySpinner.centerYAnchor.constraint(equalTo: bodyScrollView.centerYAnchor, constant: -14),
            bodyStatusField.topAnchor.constraint(equalTo: bodySpinner.bottomAnchor, constant: 10),
            bodyStatusField.centerXAnchor.constraint(equalTo: bodyScrollView.centerXAnchor),
            bodyStatusField.leadingAnchor.constraint(greaterThanOrEqualTo: root.leadingAnchor, constant: 24),
            bodyStatusField.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -24),

            emptyStateLabel.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            emptyStateLabel.centerYAnchor.constraint(equalTo: root.centerYAnchor),
        ])
        view = root
    }

    private func buildHeader(in root: NSView) {
        subjectField.font = .systemFont(ofSize: 17, weight: .semibold)
        subjectField.lineBreakMode = .byWordWrapping
        subjectField.maximumNumberOfLines = 3
        subjectField.cell?.truncatesLastVisibleLine = true
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
        expiryBanner.cell?.truncatesLastVisibleLine = true

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
            // At or below the split items' holding priorities (240–260): a long
            // subject or To: line truncates in the pane rather than shoving
            // the sidebar. 490 was enough to spare the window (priority 500)
            // but still beat every pane.
            view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        root.addSubview(headerStack)
    }

    private func buildBody(in root: NSView) {
        // HTML is decoded to an attributed string and sanitised; the view
        // itself never loads a URL. Graphics stay off so a stray attachment
        // character cannot paint an image into the pane.
        bodyView.isEditable = false
        bodyView.isSelectable = true
        bodyView.isRichText = true
        bodyView.importsGraphics = false
        bodyView.drawsBackground = false
        bodyView.font = NoteFormatting.bodyFont
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

    override func viewDidLoad() {
        super.viewDidLoad()
        startObserving()
        rebind()
    }

    /// Wrapping fields report their unwrapped single-line width until they
    /// know the column they are in. Pin that before the next layout so a
    /// long subject cannot advertise a several-thousand-point fitting size.
    override func viewDidLayout() {
        super.viewDidLayout()
        updateWrappingWidths()
    }

    private func updateWrappingWidths() {
        let width = max(0, view.bounds.width - 2 * Self.headerInset)
        guard subjectField.preferredMaxLayoutWidth != width else { return }
        subjectField.preferredMaxLayoutWidth = width
        expiryBanner.preferredMaxLayoutWidth = width
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
    }

    @objc private func plannerSelectionDidChange(_ notification: Notification) {
        let fields = notification.userInfo?[SelectionUserInfoKey.changedFields] as? Set<String> ?? []
        guard fields.contains(SelectionField.message.rawValue)
            || fields.contains(SelectionField.mailbox.rawValue) else { return }
        rebind()
    }

    /// A refresh can retire the message the reader is showing.
    @objc private func mailDidChange(_ notification: Notification) { rebind() }

    @objc private func mailDetailDidChange(_ notification: Notification) {
        let id = notification.userInfo?[MailChangeUserInfoKey.messageID] as? Int64
        // A body that arrives for a message the user has already moved on from
        // must not paint over the one on screen.
        guard id == displayedMessageID else { return }
        updateBody()
    }

    // MARK: - Binding

    func rebind() {
        switch selection.message {
        case let .recent(id)?:
            guard let message = mail.message(id: id) else { return showEmptyState() }
            bindRecent(message, id: id)
        case let .saved(uuid)?:
            guard let message = model.savedMessage(uuid: uuid) else { return showEmptyState() }
            bindSaved(message)
        case nil:
            showEmptyState()
        }
    }

    private func beginBinding() {
        emptyStateLabel.isHidden = true
        headerStack.isHidden = false
        bodyScrollView.isHidden = false
    }

    private func bindRecent(_ message: MailMessage, id: Int64) {
        displayedMessageID = id
        displayedSavedUUID = nil
        beginBinding()

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
    }

    /// A saved message needs no fetch: the copy in the store *is* the message,
    /// which is the whole reason saving is a copy rather than a bookmark.
    private func bindSaved(_ message: SavedMessage) {
        displayedSavedUUID = message.uuid
        // Outlook's id is kept only as a best-effort handle for Open in
        // Outlook, and is expected to go stale.
        displayedMessageID = message.outlookID == 0 ? nil : message.outlookID
        beginBinding()

        subjectField.stringValue = message.subject.isEmpty ? "(No subject)" : message.subject
        senderField.stringValue = MailLabels.senderLine(
            name: message.senderName,
            address: message.senderAddress
        )
        dateField.stringValue = MailLabels.readerTimestamp(for: message.receivedAt, calendar: calendar)

        if let line = MailLabels.recipientsLine(message.recipients) {
            recipientsField.stringValue = line
            recipientsField.isHidden = false
        } else {
            recipientsField.isHidden = true
        }
        if let line = MailLabels.attachmentsIndicator(
            count: message.attachmentNameList.count,
            hasAttachments: message.hasAttachments
        ) {
            attachmentsField.stringValue = "📎 \(line)"
            attachmentsField.isHidden = false
        } else {
            attachmentsField.isHidden = true
        }

        // Saved mail does not expire; that is what saving it was for.
        expiryBanner.isHidden = true
        updateConversationPosition(for: message)

        setBodyLoading(false)
        bodyStatusField.isHidden = true
        showBody(html: message.htmlBody, plain: message.body ?? "")
    }

    private func updateConversationPosition(for message: SavedMessage) {
        let conversation = conversationProvider?(message.uuid) ?? []
        guard conversation.count > 1,
              let index = conversation.firstIndex(where: { $0.uuid == message.uuid })
        else {
            conversationField.isHidden = true
            return
        }
        conversationField.stringValue = MailLabels.conversationPosition(
            index: index,
            of: conversation.count
        )
        conversationField.isHidden = false
    }

    private func showEmptyState() {
        displayedMessageID = nil
        displayedSavedUUID = nil
        emptyStateLabel.isHidden = false
        headerStack.isHidden = true
        bodyScrollView.isHidden = true
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
        let notice = MailLabels.expiryNotice(expiry: expiry, now: now(), calendar: calendar)
        expiryBanner.stringValue = notice
        // The banner is styled as a quiet caption, which VoiceOver would
        // otherwise read as just another line of the header.
        expiryBanner.setAccessibilityLabel("Expiry. \(notice)")
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
        if let line = MailLabels.attachmentsIndicator(
            count: names.count,
            hasAttachments: detail?.hasAttachments ?? false
        ) {
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
            showBody(html: detail.html, plain: detail.body)
            updateRecipientsAndAttachments()
        case .loading, .idle:
            // Keep whatever is already on screen while a body loads: blanking
            // it makes re-selecting a message you have already read flicker.
            setBodyLoading(true)
            bodyStatusField.isHidden = true
            if mail.cachedDetail(for: id) == nil { showBody(html: nil, plain: "") }
        case .failed(let message):
            setBodyLoading(false)
            bodyStatusField.stringValue = message
            bodyStatusField.isHidden = false
            showBody(html: nil, plain: "")
        }
    }

    private func showBody(html: String?, plain: String) {
        let attributed = MailBodyFormatting.attributedString(html: html, plain: plain)
        bodyView.textStorage?.setAttributedString(attributed)
        bodyView.scroll(.zero)
    }

    /// `NSProgressIndicator` manages its own visibility when stopped, but not
    /// synchronously, so the flag is tracked rather than inferred.
    private func setBodyLoading(_ loading: Bool) {
        isBodyLoading = loading
        bodySpinner.isHidden = !loading
        if loading { bodySpinner.startAnimation(nil) } else { bodySpinner.stopAnimation(nil) }
    }

}

extension MailReaderViewController {
    var test_isEmptyStateVisible: Bool { !emptyStateLabel.isHidden }
    var test_subject: String { subjectField.stringValue }
    var test_sender: String { senderField.stringValue }
    var test_date: String { dateField.stringValue }
    var test_body: String { bodyView.string }
    var test_bodyHasBold: Bool {
        var found = false
        let storage = bodyView.textStorage
        storage?.enumerateAttribute(.font, in: NSRange(location: 0, length: storage?.length ?? 0)) { value, _, stop in
            if let font = value as? NSFont, font.fontDescriptor.symbolicTraits.contains(.bold) {
                found = true
                stop.pointee = true
            }
        }
        return found
    }
    var test_bodyLink: URL? {
        var found: URL?
        let storage = bodyView.textStorage
        storage?.enumerateAttribute(.link, in: NSRange(location: 0, length: storage?.length ?? 0)) { value, _, stop in
            if let url = value as? URL {
                found = url
                stop.pointee = true
            }
        }
        return found
    }
    var test_expiryText: String? { expiryBanner.isHidden ? nil : expiryBanner.stringValue }
    var test_bodyStatus: String? { bodyStatusField.isHidden ? nil : bodyStatusField.stringValue }
    var test_isBodyLoading: Bool { isBodyLoading }
    var test_recipients: String? { recipientsField.isHidden ? nil : recipientsField.stringValue }
    var test_attachments: String? { attachmentsField.isHidden ? nil : attachmentsField.stringValue }
    var test_displayedMessageID: Int64? { displayedMessageID }
    var test_conversationPosition: String? {
        conversationField.isHidden ? nil : conversationField.stringValue
    }
    var test_subjectTruncatesLastVisibleLine: Bool {
        subjectField.cell?.truncatesLastVisibleLine ?? false
    }
    var test_headerHorizontalCompressionResistance: CGFloat {
        CGFloat(subjectField.contentCompressionResistancePriority(for: .horizontal).rawValue)
    }
    var test_subjectPreferredMaxLayoutWidth: CGFloat { subjectField.preferredMaxLayoutWidth }
    var test_recipientsLineBreakMode: NSLineBreakMode { recipientsField.lineBreakMode }
}
