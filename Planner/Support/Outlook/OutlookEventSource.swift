import AppKit
import CoreServices
import Foundation
import ScriptingBridge

/// Reads calendar events from the Microsoft Outlook already running on this Mac.
///
/// Strictly read-only and strictly local: nothing here writes to the calendar,
/// and Planner never contacts Exchange or Microsoft 365. In particular it never
/// calls `get occurrence of`, which materializes a stored exception as a side
/// effect — that would be a write.
///
/// Three `whose` queries, each asking the matching collection for `properties`
/// so one Apple event returns every field of every match. Cost tracks the
/// *number* of queries, not the amount of data, so that count is the whole
/// performance story: ~1.9s in total, against roughly four minutes for the
/// naive per-object equivalent.
nonisolated final class OutlookEventSource: CalendarEventSource {
    struct Configuration: Sendable, Equatable {
        /// `nil` means "whichever Exchange account Outlook lists first".
        var accountName: String?
        var calendarName: String

        static let defaultCalendarName = "Calendar"

        static let accountDefaultsKey = "events.accountName"
        static let calendarDefaultsKey = "events.calendarName"

        /// Overridable through `defaults write`, pending a settings UI. A wrong
        /// name is not silent: the error names the calendars that do exist.
        static func fromDefaults(_ defaults: UserDefaults = .standard) -> Configuration {
            let account = defaults.string(forKey: accountDefaultsKey)?
                .trimmingCharacters(in: .whitespaces)
            let calendar = defaults.string(forKey: calendarDefaultsKey)?
                .trimmingCharacters(in: .whitespaces)
            return Configuration(
                accountName: (account?.isEmpty ?? true) ? nil : account,
                calendarName: (calendar?.isEmpty ?? true) ? defaultCalendarName : calendar!
            )
        }
    }

    let sourceID = "outlook"
    var displayName: String { configuration.calendarName }

    private let configuration: Configuration
    /// Apple events block the caller and `SBApplication` wants thread affinity,
    /// which an actor's cooperative pool cannot promise. A dedicated serial
    /// queue gives both, serializes refreshes for free, and guarantees that no
    /// ScriptingBridge object — none of which are `Sendable` — ever escapes it.
    private let queue = DispatchQueue(label: "com.rihscb.Planner.outlook", qos: .utility)

    init(configuration: Configuration = .fromDefaults()) {
        self.configuration = configuration
    }

    func events(in range: Range<Date>, userInitiated: Bool) async throws -> [CalendarEvent] {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [configuration] in
                continuation.resume(with: Result {
                    try Self.fetch(
                        in: range,
                        configuration: configuration,
                        userInitiated: userInitiated
                    )
                })
            }
        }
    }

    // MARK: - Preflight

    /// `SBApplication` launches its target lazily on the first send, so without
    /// this check merely opening Planner would boot Outlook.
    static var isOutlookRunning: Bool {
        !NSRunningApplication
            .runningApplications(withBundleIdentifier: OutlookScripting.bundleIdentifier)
            .isEmpty
    }

    /// Reads TCC consent **without** prompting, so launch can show a quiet
    /// affordance rather than firing a system dialog at a moment the user did
    /// not choose.
    static func automationPermission() -> AutomationPermission {
        let target = NSAppleEventDescriptor(
            bundleIdentifier: OutlookScripting.bundleIdentifier
        )
        guard let address = target.aeDesc else { return .targetMissing }
        return AutomationPermission(status: AEDeterminePermissionToAutomateTarget(
            address, typeWildCard, typeWildCard, false
        ))
    }

    /// The send is what raises the TCC dialog, so an automatic refresh must
    /// not reach it while consent is still undetermined.
    static func allowFetch(permission: AutomationPermission, userInitiated: Bool) throws {
        switch permission {
        case .denied:
            throw OutlookError.permissionDenied
        case .notDetermined where !userInitiated:
            throw OutlookError.consentRequired
        case .notDetermined, .granted, .targetMissing:
            return
        }
    }

    // MARK: - The fetch

    private static func fetch(
        in range: Range<Date>,
        configuration: Configuration,
        userInitiated: Bool
    ) throws -> [CalendarEvent] {
        guard isOutlookRunning else { throw OutlookError.notRunning }
        try allowFetch(permission: automationPermission(), userInitiated: userInitiated)

        guard let app = SBApplication(bundleIdentifier: OutlookScripting.bundleIdentifier) else {
            throw OutlookError.scriptingUnavailable
        }
        app.sendMode = AESendMode(kAEWaitReply | kAENeverInteract)
        app.timeout = OutlookScripting.timeoutTicks

        let started = Date()
        let calendar = Calendar.current
        let (events, calendarName) = try resolveCalendarEvents(app, configuration: configuration)

        let snapshot = OutlookSnapshot(
            calendarName: calendarName,
            plain: try decode(events, matching: OutlookScripting.Query.plain(in: range), app: app, calendar: calendar),
            masters: try decode(events, matching: OutlookScripting.Query.masters(), app: app, calendar: calendar),
            exceptions: try decode(events, matching: OutlookScripting.Query.exceptions(), app: app, calendar: calendar)
        )

        let result = OutlookAgenda.build(snapshot, in: range, calendar: calendar)
        // Counts and timings only — subjects, locations and organizers are
        // someone else's calendar content and never reach the log.
        PlannerLog.events.info(
            """
            Outlook fetch: \(snapshot.plain.count, privacy: .public) plain, \
            \(snapshot.masters.count, privacy: .public) masters, \
            \(snapshot.exceptions.count, privacy: .public) exceptions \
            -> \(result.count, privacy: .public) events \
            in \(Int(Date().timeIntervalSince(started) * 1000), privacy: .public)ms
            """
        )
        return result
    }

    private static func decode(
        _ events: SBElementArray,
        matching predicate: NSPredicate,
        app: SBApplication,
        calendar: Calendar
    ) throws -> [OutlookRawEvent] {
        guard let matches = filtered(events, predicate) else {
            try OutlookError.throwIfSendFailed(app.lastError())
            return []
        }
        return OutlookRecordDecoder.rawEvents(
            try propertyDictionaries(of: matches, app: app),
            calendar: calendar
        )
    }

    private static func resolveCalendarEvents(
        _ app: SBApplication,
        configuration: Configuration
    ) throws -> (SBElementArray, String) {
        guard let accounts = try requiredElements(app, OutlookScripting.Element.exchangeAccounts) else {
            throw OutlookError.scriptingUnavailable
        }
        let accountRecords = try accountIdentities(of: accounts, app: app)
        guard !accountRecords.isEmpty else { throw OutlookError.noExchangeAccounts }

        let accountNames = accountRecords.compactMap(\.name)
        let account: (id: NSNumber, name: String?)
        if let wanted = configuration.accountName {
            guard let match = accountRecords.first(where: { $0.name == wanted }) else {
                throw OutlookError.accountNotFound(name: wanted, available: accountNames)
            }
            account = match
        } else {
            account = accountRecords[0]
        }
        let accountID = account.id

        guard let calendars = try requiredElements(app, OutlookScripting.Element.calendars) else {
            throw OutlookError.scriptingUnavailable
        }
        // One dictionary per calendar rather than parallel per-property arrays:
        // `array(byApplying:)` cannot represent a nil result, so a calendar with
        // no name drops out and every later index silently refers to a
        // different calendar than the ids array does.
        let calendarRecords = try propertyDictionaries(of: calendars, app: app).filter {
            OutlookRecordDecoder.accountID($0[OutlookScripting.Key.account]) == accountID
        }

        guard let match = calendarRecords.first(where: {
            OutlookRecordDecoder.string($0[OutlookScripting.Key.name]) == configuration.calendarName
        }), let calendarID = match[OutlookScripting.Key.id] as? NSNumber else {
            throw OutlookError.calendarNotFound(
                name: configuration.calendarName,
                available: calendarRecords.compactMap {
                    OutlookRecordDecoder.string($0[OutlookScripting.Key.name])
                }
            )
        }

        guard let folder = calendars.object(withID: calendarID) as AnyObject? else {
            try OutlookError.throwIfSendFailed(app.lastError())
            throw OutlookError.scriptingUnavailable
        }
        guard let events = try requiredElements(app, OutlookScripting.Element.calendarEvents, of: folder) else {
            throw OutlookError.scriptingUnavailable
        }
        return (events, configuration.calendarName)
    }

    // MARK: - Dynamic dispatch

    // See `OutlookScripting` for why none of this uses a generated header.

    private static func elements(_ object: AnyObject, _ name: String) -> SBElementArray? {
        let selector = NSSelectorFromString(name)
        guard object.responds(to: selector) else { return nil }
        return object.perform(selector)?.takeUnretainedValue() as? SBElementArray
    }

    private static func requiredElements(
        _ app: SBApplication,
        _ name: String,
        of object: AnyObject? = nil
    ) throws -> SBElementArray? {
        let result = elements(object ?? app, name)
        try OutlookError.throwIfSendFailed(app.lastError())
        return result
    }

    /// `filteredArrayUsingPredicate:` builds a lazy specifier that becomes a
    /// `whose` clause on the wire. Sent through the ObjC runtime rather than
    /// Swift's `filtered(using:)`, which bridges to a Swift `Array` and would
    /// force the collection to evaluate one object at a time.
    private static func filtered(
        _ array: SBElementArray,
        _ predicate: NSPredicate
    ) -> SBElementArray? {
        let selector = NSSelectorFromString("filteredArrayUsingPredicate:")
        guard array.responds(to: selector) else { return nil }
        return array.perform(selector, with: predicate)?.takeUnretainedValue() as? SBElementArray
    }

    /// Accounts, read one object at a time.
    ///
    /// Unlike calendars and events, an Exchange account does **not** answer the
    /// `properties` pseudo-property — the bulk call comes back empty rather
    /// than failing, which would strand the fetch on "no Exchange accounts".
    /// Reading per object costs a couple of round trips for the one-to-three
    /// accounts that exist, and is index-safe by construction, so it is the
    /// right trade here even though it would be ruinous for events.
    private static func accountIdentities(
        of accounts: SBElementArray,
        app: SBApplication
    ) throws -> [(id: NSNumber, name: String?)] {
        var records: [(id: NSNumber, name: String?)] = []
        for element in accounts as NSArray {
            let object = element as AnyObject
            let id = object.value(forKey: OutlookScripting.Key.id) as? NSNumber
            try OutlookError.throwIfSendFailed(app.lastError())
            guard let id else { continue }
            records.append(
                (id, OutlookRecordDecoder.string(object.value(forKey: OutlookScripting.Key.name)))
            )
        }
        return records
    }

    private static func propertyDictionaries(
        of array: SBElementArray,
        app: SBApplication
    ) throws -> [[AnyHashable: Any]] {
        let values = array.array(byApplying: NSSelectorFromString(OutlookScripting.properties))
        try OutlookError.throwIfSendFailed(app.lastError())
        return values.compactMap { $0 as? [AnyHashable: Any] }
    }
}
