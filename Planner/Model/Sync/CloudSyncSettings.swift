import Foundation

/// The CloudKit mirroring preference, resolved once per launch.
///
/// Sync is opt-in, and the decision is read exactly once — at store load, where
/// `PersistenceController` either attaches `NSPersistentCloudKitContainerOptions`
/// to the store description or leaves it off. A store cannot be re-pointed at a
/// CloudKit container while it is open, so toggling writes the preference and
/// says it applies at the next launch rather than pretending to switch live.
///
/// Keeping this a value type (rather than reading `UserDefaults` at the point of
/// use) is what lets tests build a controller with sync off, or with a throwaway
/// container identifier, without touching the developer's real defaults.
nonisolated struct CloudSyncSettings: Sendable, Equatable {
    /// `DESIGN.md` fixes the bundle identifier as `com.rihscb.Planner`; the
    /// CloudKit container follows Apple's `iCloud.` + bundle-id convention, and
    /// must match `com.apple.developer.icloud-container-identifiers` in
    /// `Planner.entitlements`.
    static let defaultContainerIdentifier = "iCloud.com.rihscb.Planner"

    /// `UserDefaults` keys. The container override exists for the same reason
    /// the Outlook calendar name has one (DESIGN §8.6): a wrong value should be
    /// fixable without a rebuild.
    enum Key {
        static let enabled = "CloudSyncEnabled"
        static let containerIdentifier = "CloudKitContainerIdentifier"
        static let historyToken = "CloudSyncHistoryToken"
    }

    var isEnabled: Bool
    var containerIdentifier: String

    /// The shipped default: local-only, exactly as every version before this one.
    static let disabled = CloudSyncSettings(isEnabled: false)

    init(isEnabled: Bool, containerIdentifier: String = CloudSyncSettings.defaultContainerIdentifier) {
        self.isEnabled = isEnabled
        self.containerIdentifier = containerIdentifier
    }

    /// Reads the preference. An absent key is `false`: an existing install does
    /// not start uploading because it was updated.
    init(defaults: UserDefaults) {
        self.isEnabled = defaults.bool(forKey: Key.enabled)
        let override = defaults.string(forKey: Key.containerIdentifier)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        self.containerIdentifier = (override?.isEmpty == false)
            ? override!
            : Self.defaultContainerIdentifier
    }

    static func setEnabled(_ enabled: Bool, in defaults: UserDefaults) {
        defaults.set(enabled, forKey: Key.enabled)
    }
}
