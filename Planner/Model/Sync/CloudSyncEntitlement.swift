import Foundation
import Security

/// What iCloud containers this build is actually signed for.
///
/// Worth asking before touching CloudKit at all, because the two APIs behind
/// mirroring fail in opposite and equally unhelpful ways when the entitlement is
/// missing. `NSPersistentCloudKitContainer` loads the store happily and then
/// simply never syncs — no error, no event worth showing. `CKContainer(identifier:)`
/// does the reverse: it raises an Objective-C exception and takes the process
/// down, which is not something Swift can catch.
///
/// So the check has to happen first. A build without the entitlement reports
/// "not signed for iCloud" and stays local, which is both true and actionable;
/// the alternative is a silent no-op or a crash on launch.
nonisolated enum CloudSyncEntitlement {
    static let key = "com.apple.developer.icloud-container-identifiers"

    /// Reads this process's own code signature. Empty for an unsigned or ad-hoc
    /// build — which the project no longer produces, but a stale binary or a
    /// build signed by another team still can.
    static func declaredContainers() -> [String] {
        guard let task = SecTaskCreateFromSelf(nil) else { return [] }
        let value = SecTaskCopyValueForEntitlement(task, key as CFString, nil)
        return value as? [String] ?? []
    }

    static func isSigned(forContainer identifier: String) -> Bool {
        declaredContainers().contains(identifier)
    }
}
