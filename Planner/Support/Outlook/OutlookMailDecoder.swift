import Foundation

/// Turns the Apple event descriptors `NSAppleScript` returns into Planner's own
/// types.
///
/// Pure and synchronous by design, like `OutlookRecordDecoder`: all the
/// descriptor-shaped knowledge lives here so it can be tested against captured
/// payloads, which leaves `OutlookMailSource` thin enough to review by eye.
nonisolated enum OutlookMailDecoder {
    // MARK: - Scalars

    /// AppleScript's `missing value` arrives as a null descriptor, and an empty
    /// string is the same as none for every field Planner reads.
    static func string(_ descriptor: NSAppleEventDescriptor?) -> String? {
        guard let descriptor, descriptor.descriptorType != typeNull else { return nil }
        guard let value = descriptor.stringValue else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Empty HTML is the same as none: the reader then falls back to plain text.
    private static func nonempty(_ value: String?) -> String? {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return value
    }

    /// Kept verbatim — bodies are the one place trailing whitespace is content
    /// rather than noise.
    static func rawString(_ descriptor: NSAppleEventDescriptor?) -> String? {
        guard let descriptor, descriptor.descriptorType != typeNull else { return nil }
        return descriptor.stringValue
    }

    /// Record ids are `integer` in the sdef, which AppleScript hands back as a
    /// 32-bit descriptor today. Reading the string form as well means a future
    /// 64-bit id does not silently truncate to a wrong — but plausible — id.
    static func identifier(_ descriptor: NSAppleEventDescriptor?) -> Int64? {
        guard let descriptor, descriptor.descriptorType != typeNull else { return nil }
        if let text = descriptor.stringValue, let value = Int64(text) { return value }
        let value = descriptor.int32Value
        return value == 0 ? nil : Int64(value)
    }

    static func date(_ descriptor: NSAppleEventDescriptor?) -> Date? {
        guard let descriptor, descriptor.descriptorType != typeNull else { return nil }
        return descriptor.dateValue
    }

    static func bool(_ descriptor: NSAppleEventDescriptor?) -> Bool {
        guard let descriptor, descriptor.descriptorType != typeNull else { return false }
        return descriptor.booleanValue
    }

    static func list(_ descriptor: NSAppleEventDescriptor?) -> [NSAppleEventDescriptor] {
        guard let descriptor, descriptor.numberOfItems > 0 else { return [] }
        return (1...descriptor.numberOfItems).compactMap { descriptor.atIndex($0) }
    }

    static func strings(_ descriptor: NSAppleEventDescriptor?) -> [String] {
        list(descriptor).compactMap { string($0) }
    }

    // MARK: - Messages

    /// Decodes the five parallel columns the envelope query returns.
    ///
    /// The columns are index-aligned — AppleScript returns `missing value` in
    /// place rather than dropping it, unlike ScriptingBridge's
    /// `array(byApplying:)`, which is what forced one-dictionary-per-object on
    /// the calendar side. Mismatched counts would mean that assumption had
    /// broken, so they fail the decode rather than shifting every later row
    /// onto the wrong message.
    static func envelopes(_ payload: NSAppleEventDescriptor?) throws -> [MailMessage] {
        let columns = list(payload)
        guard columns.count == 5 else { throw OutlookError.scriptingUnavailable }

        let ids = list(columns[0])
        let subjects = list(columns[1])
        let times = list(columns[2])
        let read = list(columns[3])
        let senders = list(columns[4])

        let counts = [ids.count, subjects.count, times.count, read.count, senders.count]
        guard Set(counts).count == 1 else { throw OutlookError.misalignedPayload }

        return (0..<ids.count).compactMap { index in
            // A record missing the two fields every message must have is
            // skipped; it never fails the whole sweep.
            guard let id = identifier(ids[index]), let receivedAt = date(times[index]) else {
                return nil
            }
            let sender = senders[index]
            return MailMessage(
                id: id,
                subject: string(subjects[index]) ?? "",
                senderName: string(sender.forKeyword(OutlookMailScripting.SenderKey.name)) ?? "",
                senderAddress: string(sender.forKeyword(OutlookMailScripting.SenderKey.address)) ?? "",
                receivedAt: receivedAt,
                isRead: bool(read[index])
            )
        }
    }

    /// Decodes the two-column id / is-read scan used by an incremental sweep.
    static func indexScan(_ payload: NSAppleEventDescriptor?) throws -> [(id: Int64, isRead: Bool)] {
        let columns = list(payload)
        guard columns.count == 2 else { throw OutlookError.scriptingUnavailable }
        let ids = list(columns[0])
        let read = list(columns[1])
        guard ids.count == read.count else { throw OutlookError.misalignedPayload }
        return (0..<ids.count).compactMap { index in
            guard let id = identifier(ids[index]) else { return nil }
            return (id, bool(read[index]))
        }
    }

    /// Decodes the body/headers/attachments reply. A fourth element is the
    /// HTML `content`; older three-element payloads still decode, with no HTML.
    static func detail(_ payload: NSAppleEventDescriptor?, id: Int64) -> MailMessageDetail {
        let parts = list(payload)
        let body = parts.count > 0 ? rawString(parts[0]) : nil
        let headers = parts.count > 1 ? rawString(parts[1]) : nil
        let names = parts.count > 2 ? strings(parts[2]) : []
        let html = parts.count > 3 ? nonempty(rawString(parts[3])) : nil
        let parsed = MailHeaders.parse(headers)

        return MailMessageDetail(
            id: id,
            body: body ?? "",
            html: html,
            messageID: parsed.messageID,
            inReplyTo: parsed.inReplyTo,
            references: parsed.references,
            recipients: parsed.recipients,
            // The attachment list is authoritative when it is there; the
            // Exchange header is the fallback for a message whose attachments
            // could not be enumerated.
            hasAttachments: !names.isEmpty || parsed.hasAttachments,
            attachmentNames: names.isEmpty ? nil : names.joined(separator: "\n")
        )
    }
}
