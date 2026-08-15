import Foundation

/// Groups saved messages into conversations.
///
/// Threading is a **view** of a folder, not data: it is recomputed from stored
/// headers every time the list draws, and nothing about thread membership is
/// persisted. Storing it would mean repairing it on every save, move and
/// remove, and the repair would be wrong exactly when a reference chain is
/// broken — which is the case this has to handle well anyway.
///
/// Pure and synchronous, over plain values rather than managed objects, so the
/// whole of it is testable against a fixture corpus with no store in sight.
nonisolated enum MailThreading {
    /// One message, reduced to the fields threading actually reads.
    struct Message: Hashable, Sendable, Identifiable {
        let id: UUID
        /// RFC 822 Message-ID, or the synthetic fallback `ModelController`
        /// assigns when the header was missing.
        let messageID: String
        let subject: String
        /// Sender and recipients, lower-cased addresses. The subject fallback
        /// only joins messages that share at least one.
        let participants: Set<String>
        let receivedAt: Date
        let inReplyTo: String?
        let references: String?

        init(
            id: UUID,
            messageID: String,
            subject: String,
            participants: Set<String>,
            receivedAt: Date,
            inReplyTo: String? = nil,
            references: String? = nil
        ) {
            self.id = id
            self.messageID = messageID
            self.subject = subject
            self.participants = participants
            self.receivedAt = receivedAt
            self.inReplyTo = inReplyTo
            self.references = references
        }
    }

    /// A conversation: its messages newest-first, and the subject to label it
    /// with.
    struct Thread: Hashable, Sendable, Identifiable {
        /// The newest message's id, which is stable for as long as the thread
        /// has that message in it — enough to keep an outline row expanded
        /// across a reload.
        var id: UUID { messages[0].id }
        let subject: String
        /// Newest first, matching the list.
        let messages: [Message]

        var latestDate: Date { messages[0].receivedAt }
        var count: Int { messages.count }

        /// Everyone who appears anywhere in the conversation, for the row's
        /// participant line.
        var participants: Set<String> {
            messages.reduce(into: Set<String>()) { $0.formUnion($1.participants) }
        }
    }

    // MARK: - Threading

    /// Threads ordered newest-conversation-first; messages inside each thread
    /// newest-first. Ties break on uuid so the order cannot drift between
    /// reloads.
    static func threads(_ messages: [Message]) -> [Thread] {
        guard !messages.isEmpty else { return [] }

        var union = UnionFind()
        // Every id a message *mentions* gets a node, including ids for
        // messages that are not in this folder: two replies to a message the
        // user never saved still join through their common ancestor.
        for message in messages {
            union.makeSet(message.messageID)
            for reference in chain(of: message) {
                union.makeSet(reference)
                union.union(message.messageID, reference)
            }
        }

        joinBySubject(messages, into: &union)

        var buckets: [String: [Message]] = [:]
        for message in messages {
            buckets[union.find(message.messageID), default: []].append(message)
        }

        return buckets.values
            .map(makeThread)
            .sorted {
                $0.latestDate == $1.latestDate ? $0.id < $1.id : $0.latestDate > $1.latestDate
            }
    }

    /// The subject fallback, for the common case of a chain broken by a client
    /// that dropped `References`.
    ///
    /// Requires a **participant overlap** as well as a matching subject.
    /// Without that, every "Re: Lunch?" in a folder collapses into one
    /// conversation, which is worse than showing them apart.
    private static func joinBySubject(_ messages: [Message], into union: inout UnionFind) {
        var bySubject: [String: [Message]] = [:]
        for message in messages {
            let key = normalizedSubject(message.subject).lowercased()
            guard !key.isEmpty else { continue }
            bySubject[key, default: []].append(message)
        }

        for group in bySubject.values where group.count > 1 {
            for (index, message) in group.enumerated() {
                for other in group[(index + 1)...]
                where !message.participants.isDisjoint(with: other.participants) {
                    union.union(message.messageID, other.messageID)
                }
            }
        }
    }

    private static func makeThread(_ messages: [Message]) -> Thread {
        let ordered = messages.sorted {
            $0.receivedAt == $1.receivedAt ? $0.id < $1.id : $0.receivedAt > $1.receivedAt
        }
        // Labelled from the newest message: a thread that has been renamed
        // mid-conversation reads under the name it is being carried on now.
        let normalized = normalizedSubject(ordered[0].subject)
        return Thread(
            subject: normalized.isEmpty ? ordered[0].subject : normalized,
            messages: ordered
        )
    }

    private static func chain(of message: Message) -> [String] {
        var ids = referenceIDs(from: message.references)
        if let inReplyTo = message.inReplyTo {
            ids.append(contentsOf: referenceIDs(from: inReplyTo))
        }
        return ids
    }

    // MARK: - Header parsing

    /// Splits a `References`-style header value into its ids.
    ///
    /// Split on angle brackets rather than whitespace: real headers fold, and
    /// some clients separate ids with commas or nothing at all.
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
        // A bare id with no brackets at all is still an id. Only when there
        // were no brackets: `<>` and `<unterminated` are malformed, not bare.
        if ids.isEmpty, !header.contains("<"), !header.contains(">") {
            let bare = header.trimmingCharacters(in: .whitespacesAndNewlines)
            if !bare.isEmpty, !bare.contains(" ") { ids.append(bare) }
        }
        return ids
    }

    /// Strips reply and forward prefixes, repeatedly, and folds whitespace.
    ///
    /// Covers the localized prefixes that actually show up in a mixed
    /// German/French/English mailbox, plus the `Re[2]:` counter form. Not
    /// exhaustive by design: an unrecognised prefix costs a subject-fallback
    /// join, never a wrong one, because the participant check still applies.
    static func normalizedSubject(_ subject: String) -> String {
        var value = subject.trimmingCharacters(in: .whitespacesAndNewlines)
        var changed = true
        while changed {
            changed = false
            for prefix in prefixes {
                guard let stripped = strip(prefix: prefix, from: value) else { continue }
                value = stripped
                changed = true
                break
            }
        }
        return value
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static let prefixes = ["re", "fw", "fwd", "aw", "wg", "tr", "rif", "sv", "vs", "antw"]

    /// Matches `Re:`, `RE :`, `Re[2]:` and `Re(2):`, and nothing else — a
    /// subject that merely *starts* with the letters, like "Recipe ideas",
    /// must survive untouched.
    private static func strip(prefix: String, from value: String) -> String? {
        let lowered = value.lowercased()
        guard lowered.hasPrefix(prefix) else { return nil }
        var index = value.index(value.startIndex, offsetBy: prefix.count)

        // Optional bracketed repeat count.
        if index < value.endIndex, value[index] == "[" || value[index] == "(" {
            let closing: Character = value[index] == "[" ? "]" : ")"
            var cursor = value.index(after: index)
            var digits = 0
            while cursor < value.endIndex, value[cursor].isNumber {
                cursor = value.index(after: cursor)
                digits += 1
            }
            guard digits > 0, cursor < value.endIndex, value[cursor] == closing else { return nil }
            index = value.index(after: cursor)
        }

        while index < value.endIndex, value[index] == " " {
            index = value.index(after: index)
        }
        guard index < value.endIndex, value[index] == ":" else { return nil }
        return String(value[value.index(after: index)...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Just enough union-find for one folder's worth of messages: path compression,
/// no ranking. The sets are tiny and the code stays readable.
nonisolated private struct UnionFind {
    private var parent: [String: String] = [:]

    mutating func makeSet(_ id: String) {
        guard parent[id] == nil else { return }
        parent[id] = id
    }

    mutating func find(_ id: String) -> String {
        guard var root = parent[id] else {
            parent[id] = id
            return id
        }
        while let next = parent[root], next != root { root = next }
        // Path compression, so a long reply chain does not degrade into a walk.
        var cursor = id
        while let next = parent[cursor], next != root {
            parent[cursor] = root
            cursor = next
        }
        return root
    }

    mutating func union(_ lhs: String, _ rhs: String) {
        let left = find(lhs)
        let right = find(rhs)
        guard left != right else { return }
        // Lexicographically smallest root, so the grouping is deterministic
        // rather than dependent on the order messages were fetched in.
        if left < right { parent[right] = left } else { parent[left] = right }
    }
}
