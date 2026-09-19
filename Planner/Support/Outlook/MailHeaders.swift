import Foundation

/// Parses the RFC 822 header block Outlook hands back as one string.
///
/// Pure and synchronous, like `OutlookRecordDecoder`: this is where all the
/// fiddly header-shaped knowledge lives, so it can be tested against captured
/// payloads with no Apple event anywhere near it.
///
/// Two things about the real payload drive the whole design, both found in the
/// M0 spike: the lines are **folded** — a long value continues on the next line
/// beginning with a space or tab — and they are **CR-terminated**, not LF. A
/// naive `components(separatedBy: "\n")` finds one enormous line and every
/// lookup fails.
nonisolated enum MailHeaders {
    struct Parsed: Equatable, Sendable {
        var messageID: String?
        var inReplyTo: String?
        var references: String?
        /// `To:` and `Cc:` joined, which is the only recipient list available
        /// without a per-message element read.
        var recipients: String?
        var hasAttachments: Bool
    }

    static func parse(_ raw: String?) -> Parsed {
        guard let raw, !raw.isEmpty else {
            return Parsed(messageID: nil, inReplyTo: nil, references: nil,
                          recipients: nil, hasAttachments: false)
        }
        let lines = unfold(raw)
        let to = value(of: "to", in: lines)
        let cc = value(of: "cc", in: lines)
        let recipients = [to, cc].compactMap { $0 }.filter { !$0.isEmpty }

        return Parsed(
            messageID: bracketed(value(of: "message-id", in: lines)),
            inReplyTo: value(of: "in-reply-to", in: lines),
            references: value(of: "references", in: lines),
            recipients: recipients.isEmpty ? nil : recipients.joined(separator: ", "),
            // Exchange's own marker. Cheaper and better aligned than reading
            // the attachments element per message, and the header is already
            // being fetched for the threading ids.
            hasAttachments: value(of: "x-ms-has-attach", in: lines)?
                .lowercased()
                .contains("yes") ?? false
        )
    }

    /// Splits the block into logical header lines, joining folded continuations.
    static func unfold(_ raw: String) -> [String] {
        var lines: [String] = []
        // Both terminators, in either order: the payload uses CR, but a header
        // that has been through a Unix tool on the way will use LF.
        for line in raw.components(separatedBy: CharacterSet(charactersIn: "\r\n")) {
            guard !line.isEmpty else { continue }
            if line.hasPrefix(" ") || line.hasPrefix("\t") {
                guard !lines.isEmpty else { continue }
                // A folded continuation is one value split across lines, and
                // the fold itself is whitespace that was never in the value.
                lines[lines.count - 1] += " " + line.trimmingCharacters(in: .whitespaces)
            } else {
                lines.append(line)
            }
        }
        return lines
    }

    /// The value of the first header with this name, case-insensitively.
    static func value(of name: String, in lines: [String]) -> String? {
        let prefix = name.lowercased() + ":"
        for line in lines where line.lowercased().hasPrefix(prefix) {
            let value = String(line.dropFirst(prefix.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        }
        return nil
    }

    /// Message-IDs are compared as strings, so one that arrives without its
    /// angle brackets has to grow them or it will never match a `References`
    /// entry, which always has them.
    private static func bracketed(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        // A malformed header can carry more than one; take the first.
        if value.contains("<") {
            return referenceIDs(from: value).first
        }
        return "<\(value)>"
    }

    /// Splits a References-style value on angle brackets. Kept with header
    /// decoding now that Planner no longer builds saved-mail conversations.
    static func referenceIDs(from header: String?) -> [String] {
        guard let header, !header.isEmpty else { return [] }
        var ids: [String] = []
        var current = ""
        var inside = false
        for character in header {
            switch character {
            case "<":
                inside = true
                current = ""
            case ">":
                guard inside else { continue }
                inside = false
                let id = "<" + current.trimmingCharacters(in: .whitespacesAndNewlines) + ">"
                if id.count > 2 { ids.append(id) }
            default:
                if inside { current.append(character) }
            }
        }
        if ids.isEmpty, !header.contains("<"), !header.contains(">") {
            let bare = header.trimmingCharacters(in: .whitespacesAndNewlines)
            if !bare.isEmpty, !bare.contains(" ") { ids.append(bare) }
        }
        return ids
    }
}
