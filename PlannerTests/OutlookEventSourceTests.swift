import XCTest
@testable import Planner

/// Covers the parts of the Outlook source that do not require Outlook:
/// configuration resolution, consent-status mapping, and error copy.
///
/// The three `whose` queries themselves are the one untested surface in this
/// feature, deliberately — testing them would mean depending on a running
/// Outlook and on someone's real calendar.
final class OutlookEventSourceTests: XCTestCase {
    private typealias Configuration = OutlookEventSource.Configuration

    private func defaults(_ values: [String: String?]) -> UserDefaults {
        let suite = UserDefaults(suiteName: "OutlookEventSourceTests.\(UUID().uuidString)")!
        for (key, value) in values {
            if let value { suite.set(value, forKey: key) } else { suite.removeObject(forKey: key) }
        }
        return suite
    }

    // MARK: - Configuration

    func testDefaultsToTheFirstExchangeAccountAndACalendarNamedCalendar() {
        let configuration = Configuration.fromDefaults(defaults([:]))
        XCTAssertNil(configuration.accountName, "nil means whichever account Outlook lists first")
        XCTAssertEqual(configuration.calendarName, "Calendar")
    }

    func testDefaultsCanBeOverridden() {
        let configuration = Configuration.fromDefaults(defaults([
            Configuration.accountDefaultsKey: "work@example.com",
            Configuration.calendarDefaultsKey: "Matters",
        ]))
        XCTAssertEqual(configuration.accountName, "work@example.com")
        XCTAssertEqual(configuration.calendarName, "Matters")
    }

    /// A blank value in `defaults` is a mistake, not an instruction to look for
    /// a calendar with no name.
    func testBlankOverridesFallBackToTheDefaults() {
        let configuration = Configuration.fromDefaults(defaults([
            Configuration.accountDefaultsKey: "   ",
            Configuration.calendarDefaultsKey: "",
        ]))
        XCTAssertNil(configuration.accountName)
        XCTAssertEqual(configuration.calendarName, "Calendar")
    }

    func testDisplayNameIsTheCalendarName() {
        let source = OutlookEventSource(
            configuration: Configuration(accountName: nil, calendarName: "Matters")
        )
        XCTAssertEqual(source.displayName, "Matters")
        XCTAssertEqual(source.sourceID, "outlook")
    }

    // MARK: - Consent mapping

    func testAutomationPermissionMapsTheStatusCodesThatMatter() {
        XCTAssertEqual(AutomationPermission(status: 0), .granted)
        XCTAssertEqual(AutomationPermission(status: -1743), .denied)         // errAEEventNotPermitted
        XCTAssertEqual(AutomationPermission(status: -1744), .notDetermined)  // would require consent
        XCTAssertEqual(AutomationPermission(status: -600), .targetMissing)   // procNotFound
        XCTAssertEqual(AutomationPermission(status: -1712), .denied, "an unknown failure is not consent")
    }

    /// The preflight must never prompt, so it is safe to call at launch.
    func testAutomationPermissionPreflightIsAnswerable() {
        let permission = OutlookEventSource.automationPermission()
        XCTAssertTrue(
            [.granted, .denied, .notDetermined, .targetMissing].contains(permission),
            "got \(permission)"
        )
    }

    // MARK: - Errors

    func testOnlyDeniedConsentPointsAtSystemSettings() {
        XCTAssertTrue(OutlookError.permissionDenied.needsAutomationSettings)
        XCTAssertFalse(OutlookError.notRunning.needsAutomationSettings)
        XCTAssertFalse(OutlookError.noExchangeAccounts.needsAutomationSettings)
        XCTAssertNotNil(OutlookError.automationSettingsURL)
    }

    /// Naming what *is* there is the discovery mechanism while the account and
    /// calendar are defaults with no settings UI behind them.
    func testANotFoundErrorNamesTheAlternatives() {
        let error = OutlookError.calendarNotFound(
            name: "Matters", available: ["Calendar", "Birthdays"]
        )
        let message = error.errorDescription ?? ""
        XCTAssertTrue(message.contains("Matters"))
        XCTAssertTrue(message.contains("Calendar"), message)
        XCTAssertTrue(message.contains("Birthdays"), message)
    }

    func testANotFoundErrorWithNoAlternativesSaysSo() {
        let message = OutlookError.calendarNotFound(name: "Matters", available: []).errorDescription ?? ""
        XCTAssertTrue(message.contains("No calendars are available"), message)
    }

    /// A calendar with no name is exactly the case that broke the spike; it
    /// must not surface as an empty entry in the list of alternatives.
    func testUnnamedCalendarsAreNotOfferedAsAlternatives() {
        let message = OutlookError.calendarNotFound(
            name: "Matters", available: ["", "Calendar"]
        ).errorDescription ?? ""
        XCTAssertFalse(message.contains(", ,"), message)
        XCTAssertTrue(message.contains("Available: Calendar."), message)
    }

    func testEveryErrorHasAMessage() {
        let errors: [OutlookError] = [
            .notRunning, .permissionDenied, .scriptingUnavailable, .noExchangeAccounts,
            .accountNotFound(name: "a", available: []),
            .calendarNotFound(name: "c", available: []),
            .appleEvent(code: -1712),
            .consentRequired,
        ]
        for error in errors {
            XCTAssertFalse(error.errorDescription?.isEmpty ?? true, "\(error) needs a message")
        }
    }

    func testNotRunningTellsTheUserPlannerWillNotLaunchOutlook() {
        let suggestion = OutlookError.notRunning.recoverySuggestion ?? ""
        XCTAssertTrue(suggestion.contains("won’t launch it"), suggestion)
    }

    /// An empty collection is a successful match-nothing; a failed send must
    /// not be allowed to look like that.
    func testALastErrorBecomesAnAppleEventFailure() {
        XCTAssertThrowsError(
            try OutlookError.throwIfSendFailed(NSError(domain: NSOSStatusErrorDomain, code: -1712))
        ) { error in
            XCTAssertEqual(error as? OutlookError, .appleEvent(code: -1712))
        }
    }

    func testANilLastErrorIsSuccess() {
        XCTAssertNoThrow(try OutlookError.throwIfSendFailed(nil))
    }

    func testAConsentRevokedMidFetchMapsToPermissionDenied() {
        XCTAssertThrowsError(
            try OutlookError.throwIfSendFailed(NSError(domain: NSOSStatusErrorDomain, code: -1743))
        ) { error in
            XCTAssertEqual(error as? OutlookError, .permissionDenied)
        }
    }

    // MARK: - Consent gating

    func testAnAutomaticRefreshDoesNotPromptWhenConsentIsUndetermined() {
        XCTAssertThrowsError(
            try OutlookEventSource.allowFetch(permission: .notDetermined, userInitiated: false)
        ) { error in
            XCTAssertEqual(error as? OutlookError, .consentRequired)
        }
        XCTAssertFalse(OutlookError.consentRequired.needsAutomationSettings)
    }

    func testAnExplicitRefreshMayPromptWhenConsentIsUndetermined() {
        XCTAssertNoThrow(
            try OutlookEventSource.allowFetch(permission: .notDetermined, userInitiated: true)
        )
    }

    func testDeniedConsentFailsWhetherOrNotTheRefreshIsExplicit() {
        XCTAssertThrowsError(
            try OutlookEventSource.allowFetch(permission: .denied, userInitiated: false)
        ) { error in
            XCTAssertEqual(error as? OutlookError, .permissionDenied)
        }
        XCTAssertThrowsError(
            try OutlookEventSource.allowFetch(permission: .denied, userInitiated: true)
        ) { error in
            XCTAssertEqual(error as? OutlookError, .permissionDenied)
        }
    }

    func testGrantedConsentAlwaysProceeds() {
        XCTAssertNoThrow(try OutlookEventSource.allowFetch(permission: .granted, userInitiated: false))
        XCTAssertNoThrow(try OutlookEventSource.allowFetch(permission: .granted, userInitiated: true))
    }
}
