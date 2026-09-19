import Foundation

/// Failures the Outlook source can report, each with copy the user can act on.
///
/// Most of these are ordinary states rather than faults — Outlook not running,
/// consent not granted, a calendar renamed — so the wording avoids alarm and
/// says what to do instead.
nonisolated enum OutlookError: LocalizedError, Equatable, ExternallyResolvableError {
    case notRunning
    case permissionDenied
    case scriptingUnavailable
    case noExchangeAccounts
    case accountNotFound(name: String, available: [String])
    case calendarNotFound(name: String, available: [String])
    case appleEvent(code: Int)
    /// Consent has never been asked. An automatic refresh must not prompt;
    /// the status affordance lets the user start that conversation themselves.
    case consentRequired
    /// The parallel columns of a bulk mail read came back with different
    /// lengths, so no row can be trusted to belong to the message it appears
    /// beside. Rare enough to be a bug if it ever happens, and dangerous enough
    /// to be worth failing loudly rather than showing shuffled mail.
    case misalignedPayload

    /// Deep link for the error affordance in the toolbar (PR 15).
    static let automationSettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation"
    )

    /// Whether the fix is a trip to System Settings rather than anything in
    /// Planner. Retrying into a consent refusal just refuses again.
    var needsAutomationSettings: Bool {
        self == .permissionDenied
    }

    var settingsURL: URL? {
        needsAutomationSettings ? Self.automationSettingsURL : nil
    }

    var errorDescription: String? {
        switch self {
        case .notRunning:
            return "Microsoft Outlook isn’t running."
        case .permissionDenied:
            return "Planner isn’t allowed to control Microsoft Outlook."
        case .scriptingUnavailable:
            return "Microsoft Outlook isn’t responding to automation."
        case .noExchangeAccounts:
            return "Outlook has no Exchange accounts configured."
        case let .accountNotFound(name, available):
            return "Outlook has no Exchange account named “\(name)”."
                + Self.listing(available, of: "account")
        case let .calendarNotFound(name, available):
            return "There’s no calendar named “\(name)” in that account."
                + Self.listing(available, of: "calendar")
        case let .appleEvent(code):
            return "Outlook returned an error (\(code))."
        case .consentRequired:
            return "Planner needs permission to read Outlook."
        case .misalignedPayload:
            return "Outlook returned mail Planner couldn’t line up."
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .notRunning:
            return "Open Outlook and refresh. Planner won’t launch it for you."
        case .permissionDenied:
            return "Allow it under System Settings → Privacy & Security → Automation, then refresh."
        case .scriptingUnavailable, .appleEvent, .misalignedPayload:
            return "Try refreshing. If it keeps happening, restart Outlook."
        case .consentRequired:
            return "Click to allow access."
        case .noExchangeAccounts, .accountNotFound, .calendarNotFound:
            return nil
        }
    }

    /// ScriptingBridge leaves `lastError` set when a send failed and otherwise
    /// returns an empty collection, which is indistinguishable from a real
    /// empty match. Call this after every Apple event.
    static func throwIfSendFailed(_ lastError: Error?) throws {
        guard let lastError else { return }
        throw fromAppleEvent(code: (lastError as NSError).code)
    }

    /// `NSAppleScript` reports failures as a dictionary rather than an `Error`.
    /// The code inside is an ordinary Apple event error, so the two mechanisms
    /// converge on the same cases here.
    static func fromAppleScript(_ error: NSDictionary) -> OutlookError {
        let code = (error[NSAppleScript.errorNumber] as? NSNumber)?.intValue ?? 0
        return fromAppleEvent(code: code)
    }

    static func fromAppleEvent(code: Int) -> OutlookError {
        switch code {
        // Consent revoked mid-fetch is the same refusal the preflight maps.
        case -1743: return .permissionDenied
        case -600, -609: return .notRunning
        default: return .appleEvent(code: code)
        }
    }

    /// Whether this failure means "that one message is gone" rather than "the
    /// connection to Outlook is broken". A message can be filed, archived or
    /// deleted upstream between a sweep and a body fetch, and the reader should
    /// say so plainly instead of reporting an Apple event number.
    var isMissingObject: Bool {
        // -1728: can't get the object. -1719: invalid index.
        self == .appleEvent(code: -1728) || self == .appleEvent(code: -1719)
    }

    /// Naming what *is* there turns a configuration error into a self-service
    /// fix, which matters while the account and calendar are defaults with no
    /// settings UI behind them.
    private static func listing(_ available: [String], of kind: String) -> String {
        let named = available.filter { !$0.isEmpty }
        guard !named.isEmpty else { return " No \(kind)s are available." }
        return " Available: \(named.joined(separator: ", "))."
    }
}

/// Whether macOS will let Planner drive Outlook, established **without**
/// prompting so a launch can show a quiet affordance instead of a system dialog.
nonisolated enum AutomationPermission: Equatable {
    case granted
    case denied
    /// Never asked. The next Apple event will prompt, so only trigger one from
    /// an explicit user action.
    case notDetermined
    case targetMissing

    init(status: OSStatus) {
        switch status {
        case 0: self = .granted
        case -1743: self = .denied                  // errAEEventNotPermitted
        case -1744: self = .notDetermined           // errAEEventWouldRequireUserConsent
        case -600, -609: self = .targetMissing      // procNotFound, connectionInvalid
        default: self = .denied
        }
    }
}
