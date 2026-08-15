import AppKit

/// The calendar feed's only visible chrome.
///
/// Shows a spinner while a refresh is in flight and a warning button when one
/// failed, and **nothing at all** the rest of the time. A planner has no use
/// for a permanent "everything is fine" light; the absence of this control is
/// the success state.
@MainActor
final class EventStatusView: NSView {
    /// Retry, or — when the fix is consent rather than anything in Planner —
    /// open the Automation pane instead of retrying into the same refusal.
    var onRetry: (() -> Void)?
    var onOpenAutomationSettings: (() -> Void)?

    private let spinner = NSProgressIndicator()
    private let errorButton = NSButton()
    private var opensSettings = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize { NSSize(width: 20, height: 20) }

    private func configure() {
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.isIndeterminate = true
        spinner.translatesAutoresizingMaskIntoConstraints = false
        addSubview(spinner)

        errorButton.isBordered = false
        errorButton.bezelStyle = .inline
        errorButton.imagePosition = .imageOnly
        errorButton.image = NSImage(
            systemSymbolName: "exclamationmark.triangle",
            accessibilityDescription: "Calendar events unavailable"
        )
        errorButton.contentTintColor = .systemOrange
        errorButton.target = self
        errorButton.action = #selector(errorClicked)
        errorButton.isHidden = true
        errorButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(errorButton)

        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: centerYAnchor),
            spinner.widthAnchor.constraint(equalToConstant: 16),
            spinner.heightAnchor.constraint(equalToConstant: 16),
            errorButton.centerXAnchor.constraint(equalTo: centerXAnchor),
            errorButton.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    /// - Parameter detail: what the feed is and how far it reaches, so the
    ///   window bounds are discoverable from somewhere rather than nowhere.
    func apply(_ state: EventCoordinator.State, settingsURL: URL?, detail: String) {
        switch state {
        case .idle:
            spinner.stopAnimation(nil)
            errorButton.isHidden = true
            toolTip = nil
            isHidden = true

        case .loading:
            errorButton.isHidden = true
            spinner.startAnimation(nil)
            toolTip = "Loading events…\n\(detail)"
            isHidden = false

        case .loaded:
            spinner.stopAnimation(nil)
            errorButton.isHidden = true
            toolTip = nil
            isHidden = true

        case let .failed(message):
            spinner.stopAnimation(nil)
            errorButton.isHidden = false
            opensSettings = settingsURL != nil
            toolTip = opensSettings
                ? "\(message)\nClick to open Privacy & Security settings."
                : "\(message)\nClick to try again."
            errorButton.setAccessibilityLabel(message)
            isHidden = false
        }
    }

    @objc private func errorClicked() {
        if opensSettings { onOpenAutomationSettings?() } else { onRetry?() }
    }

    // MARK: - Test hooks

    var test_isSpinning: Bool { !isHidden && !spinner.isHidden && errorButton.isHidden }
    var test_isShowingError: Bool { !isHidden && !errorButton.isHidden }
    var test_toolTip: String? { toolTip }
    var test_opensSettings: Bool { opensSettings }
    func test_clickError() { errorClicked() }
}
