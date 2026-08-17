import Foundation

/// One message in the rolling Recent Mail window, as the source reports it.
///
/// Deliberately **not** a Core Data entity, for the same reason `CalendarEvent`
/// is not: the store is CloudKit-bound with `ModelController` as its only
/// writer, and mirroring a foreign feed into it would add a second writer and a
/// delete-reconcile problem the moment a message ages out upstream. Recent Mail
/// lives in memory for the window. A local sidecar remembers the last
/// successful sweep so the next launch can paint before Outlook answers;
/// that file is not CloudKit and is not `SavedMessage`. Messages worth
/// keeping are *copied* into `SavedMessage`, which is Planner's own data.
///
/// `Sendable` because it is the only thing that crosses back from the source's
/// own queue — no scripting object ever does.
///
/// **Body and headers are absent on purpose.** The M0 spike measured a single
/// message's full property record at 2.4 MB, and reading headers across the
/// window costs a third again on top of the envelope sweep, while a per-id read
/// costs ~10-100ms. So both are fetched lazily, one message at a time, through
/// `MailSource`.
nonisolated struct MailMessage: Hashable, Sendable, Identifiable, Codable {
    /// Outlook's record id. Stable for the life of the message and the handle
    /// every lazy read (body, headers, reveal) is addressed by.
    let id: Int64
    let subject: String
    let senderName: String
    let senderAddress: String
    let receivedAt: Date
    /// Outlook's own flag, displayed as the unread dot and **never written**.
    /// A "new since you last looked" cue, not state Planner owns.
    let isRead: Bool

    init(
        id: Int64,
        subject: String,
        senderName: String,
        senderAddress: String,
        receivedAt: Date,
        isRead: Bool
    ) {
        self.id = id
        self.subject = subject
        self.senderName = senderName
        self.senderAddress = senderAddress
        self.receivedAt = receivedAt
        self.isRead = isRead
    }

    /// The name if there is one, else the address. Sender rows in the list and
    /// the reader both want a single string and neither wants "(unknown)".
    var senderDisplayName: String {
        senderName.isEmpty ? senderAddress : senderName
    }

    func with(isRead: Bool) -> MailMessage {
        guard isRead != self.isRead else { return self }
        return MailMessage(
            id: id,
            subject: subject,
            senderName: senderName,
            senderAddress: senderAddress,
            receivedAt: receivedAt,
            isRead: isRead
        )
    }
}

/// A message's body and threading headers, fetched one message at a time.
///
/// Kept apart from `MailMessage` so the window sweep can never accidentally
/// carry it: the envelope is what makes a 164-message refresh ~10s instead of
/// minutes.
nonisolated struct MailMessageDetail: Hashable, Sendable {
    let id: Int64
    /// Plain text fallback. Prefer `html` in the reader when it is present.
    let body: String
    /// Outlook's `content` — HTML. Optional because a message can refuse it
    /// (partial download, rights-protected) the same way it can refuse a body.
    let html: String?
    let messageID: String?
    let inReplyTo: String?
    /// Space-joined, oldest first, exactly as the header carries them.
    let references: String?
    let recipients: String?
    let hasAttachments: Bool
    let attachmentNames: String?

    init(
        id: Int64,
        body: String,
        html: String? = nil,
        messageID: String? = nil,
        inReplyTo: String? = nil,
        references: String? = nil,
        recipients: String? = nil,
        hasAttachments: Bool = false,
        attachmentNames: String? = nil
    ) {
        self.id = id
        self.body = body
        self.html = html
        self.messageID = messageID
        self.inReplyTo = inReplyTo
        self.references = references
        self.recipients = recipients
        self.hasAttachments = hasAttachments
        self.attachmentNames = attachmentNames
    }
}
