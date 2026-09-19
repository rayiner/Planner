import Foundation

/// One category defined in Outlook.
///
/// Categories are **per account**: Outlook decides which ones an account offers
/// from `Categories.Record_AccountUID`, and a name is unique only within one —
/// two accounts can each define "Hide". `accountUID` is therefore part of the
/// identity, and `0` means Outlook's built-in set, which belongs to no account.
///
/// `id` addresses the category in olsyncmail's index; `recordID` is Outlook's
/// own, which is what AppleScript takes and what does not survive a profile
/// rebuild.
nonisolated struct OutlookCategory: Hashable, Sendable, Identifiable {
    static let hiddenName = "Hide"

    let id: Int64
    let name: String
    var recordID: Int64?
    var accountUID: Int64
    var account: String?
    var colorHex: String?

    init(
        id: Int64,
        name: String,
        recordID: Int64? = nil,
        accountUID: Int64 = 0,
        account: String? = nil,
        colorHex: String? = nil
    ) {
        self.id = id
        self.name = name
        self.recordID = recordID
        self.accountUID = accountUID
        self.account = account
        self.colorHex = colorHex
    }

    /// Outlook's id for this category, falling back to the local one for
    /// compatibility with category values that predate the daemon API.
    var outlookRecordID: Int64 { recordID ?? id }

    /// What to show when two accounts use the same name.
    var qualifiedName: String {
        guard let account, !account.isEmpty else { return name }
        return "\(name) — \(account)"
    }
}

/// A folder path in the local mail index. `name` is what `folder:` search uses.
nonisolated struct MailFolder: Hashable, Sendable {
    let name: String
    let messageCount: Int
}

/// One message in the rolling Recent Mail window, as the source reports it.
///
/// Deliberately **not** a Core Data entity, for the same reason `CalendarEvent`
/// is not: the store is CloudKit-bound with `ModelController` as its only
/// writer, and mirroring a foreign feed into it would add a second writer and a
/// delete-reconcile problem the moment a message ages out upstream. Recent and
/// Hidden Mail live in memory for the current window only.
///
/// `Sendable` because it is the only thing that crosses back from the source's
/// own queue — no scripting object ever does.
///
/// **Body and headers are absent on purpose.** The M0 spike measured a single
/// message's full property record at 2.4 MB, and reading headers across the
/// window costs a third again on top of the envelope sweep, while a per-id read
/// costs ~10-100ms. So both are fetched lazily, one message at a time, through
/// `MailSource`.
nonisolated struct MailMessage: Hashable, Sendable, Identifiable {
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
    /// Derived from Outlook's `Hide` category. Planner changes it only through
    /// an explicit Outlook command and never persists it as app-owned state.
    let isHidden: Bool
    /// olsyncmail category row ids. Planner uses these only in memory for
    /// virtual folders and generic category actions.
    let categoryIDs: Set<Int64>
    /// Which Outlook account holds the message. Categories are offered per
    /// account, so this is what decides which ones may be applied to it. `0`
    /// when the index has no account for the message.
    let accountUID: Int64
    /// The index's own body snippet, whitespace already collapsed. One line of
    /// it goes in the list row; the reader still fetches the real body lazily.
    /// Empty when the message has no text part.
    let preview: String

    init(
        id: Int64,
        subject: String,
        senderName: String,
        senderAddress: String,
        receivedAt: Date,
        isRead: Bool,
        isHidden: Bool = false,
        categoryIDs: Set<Int64> = [],
        accountUID: Int64 = 0,
        preview: String = ""
    ) {
        self.id = id
        self.subject = subject
        self.senderName = senderName
        self.senderAddress = senderAddress
        self.receivedAt = receivedAt
        self.isRead = isRead
        self.isHidden = isHidden
        self.categoryIDs = categoryIDs
        self.accountUID = accountUID
        self.preview = preview
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
            isRead: isRead,
            isHidden: isHidden,
            categoryIDs: categoryIDs,
            accountUID: accountUID,
            preview: preview
        )
    }

    func with(isHidden: Bool) -> MailMessage {
        guard isHidden != self.isHidden else { return self }
        return MailMessage(
            id: id,
            subject: subject,
            senderName: senderName,
            senderAddress: senderAddress,
            receivedAt: receivedAt,
            isRead: isRead,
            isHidden: isHidden,
            categoryIDs: categoryIDs,
            accountUID: accountUID,
            preview: preview
        )
    }

    func with(categoryID: Int64, present: Bool) -> MailMessage {
        var next = categoryIDs
        if present {
            next.insert(categoryID)
        } else {
            next.remove(categoryID)
        }
        guard next != categoryIDs else { return self }
        return MailMessage(
            id: id,
            subject: subject,
            senderName: senderName,
            senderAddress: senderAddress,
            receivedAt: receivedAt,
            isRead: isRead,
            isHidden: isHidden,
            categoryIDs: next,
            accountUID: accountUID,
            preview: preview
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
