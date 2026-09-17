import Foundation

/// How a message becomes a one-line summary request, and how the model's
/// answer becomes a line the list can show.
///
/// Pure functions, kept apart from the coordinator so the prompt shape and
/// the cleanup rules are testable without a model. The on-device model has a
/// small context window (4,096 tokens on macOS 26), so the body is cut hard:
/// quoted reply chains go first, then whatever is left past `bodyLimit`.
nonisolated enum MailSummaryPrompt {
    /// Roughly a thousand tokens of body. Leaves ample room for the
    /// instructions, the envelope, and the reply inside the smallest window
    /// the model has shipped with.
    static let bodyLimit = 4_000
    /// The retry length after the model says the prompt did not fit anyway.
    static let shortBodyLimit = 1_500
    /// One sentence, with slack for the model to finish it.
    static let maximumResponseTokens = 60
    /// The longest line worth showing under a subject. Anything past this is
    /// no longer a summary.
    static let maximumSummaryLength = 240

    /// No worked example on purpose. An earlier draft included one, and the
    /// model repeated it word for word as the summary of a message with no
    /// body.
    ///
    /// The sender's voice, and no names: the row already shows who it is
    /// from, so "Grace asks for the numbers" spends a third of the line
    /// repeating the line above it. "Please send the Q3 numbers by Friday"
    /// reads as the message itself, condensed.
    static let instructions = """
        You condense emails into one line for the message list of a busy professional's mail app.
        Reply with exactly one plain sentence of at most 25 words that states the gist of the email \
        the way the sender would say it, in the first person, including what the reader is asked \
        to do, if anything.
        Do not mention anyone's name. Do not say what kind of message it is or who it is from. \
        Do not repeat the subject line verbatim.
        Do not start with "This email", "The email", "The sender" or "I am writing".
        Do not announce the message ("I’m asking you to", "I’m sharing", "I wanted to let you know"); \
        state the request or the news itself.
        No preamble, no quotation marks, no markdown, no bullet points, no emoji. Never call a tool.
        Use only what the email says; never invent details, dates or requests.
        """

    static func request(for message: MailMessage, body: String, bodyLimit: Int = bodyLimit) -> OnDeviceModelRequest {
        let trimmedBody = truncated(body, limit: bodyLimit)
        let prompt = """
            Condense the email below into one first-person sentence, as its sender would put it.

            Subject: \(message.subject.isEmpty ? "(No subject)" : message.subject)

            \(trimmedBody.isEmpty ? "(The message has no body text; work from the subject alone.)" : trimmedBody)
            """
        return OnDeviceModelRequest(
            instructions: instructions,
            prompt: prompt,
            maximumResponseTokens: maximumResponseTokens,
            temperature: 0.2
        )
    }

    /// The body as text: Outlook's plain-text rendering when it has one, else
    /// the HTML with its tags stripped. Regex rather than the AppKit HTML
    /// importer — this runs off the main thread and must not load anything.
    static func plainBody(from detail: MailMessageDetail) -> String {
        let plain = detail.body.trimmingCharacters(in: .whitespacesAndNewlines)
        if !plain.isEmpty { return plain }
        guard let html = detail.html else { return "" }
        return stripHTML(html)
    }

    /// Drops quoted earlier messages and collapses whitespace, then cuts at
    /// `limit` on a word boundary.
    static func truncated(_ body: String, limit: Int = bodyLimit) -> String {
        var text = withoutQuotedReplies(body)
        text = text.replacingOccurrences(of: "\r\n", with: "\n")
        text = collapseBlankLines(text)
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count > limit else { return text }
        let cut = text.index(text.startIndex, offsetBy: limit)
        var head = String(text[..<cut])
        if let lastSpace = head.lastIndex(where: { $0 == " " || $0 == "\n" }),
           head.distance(from: head.startIndex, to: lastSpace) > limit / 2 {
            head = String(head[..<lastSpace])
        }
        return head.trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }

    /// Everything from the first reply-chain marker onward. The marker has to
    /// sit past the first few lines: a forwarded message that *starts* with
    /// "From:" is the content, not a quote.
    static func withoutQuotedReplies(_ body: String) -> String {
        let minimumOffset = 80
        var earliest: String.Index?
        for pattern in quoteMarkers {
            guard let match = pattern.firstMatch(
                in: body,
                range: NSRange(body.startIndex..., in: body)
            ), let range = Range(match.range, in: body) else { continue }
            guard body.distance(from: body.startIndex, to: range.lowerBound) >= minimumOffset else { continue }
            if earliest == nil || range.lowerBound < earliest! { earliest = range.lowerBound }
        }
        guard let earliest else { return body }
        return String(body[..<earliest])
    }

    private static let quoteMarkers: [NSRegularExpression] = {
        let sources = [
            #"^-{2,}\s*Original Message\s*-{2,}"#,
            #"^-{2,}\s*Forwarded message\s*-{2,}"#,
            #"^From:\s.+\n(Sent|Date):\s"#,
            #"^On .{1,120} wrote:\s*$"#,
        ]
        return sources.map {
            try! NSRegularExpression(pattern: $0, options: [.anchorsMatchLines, .caseInsensitive])
        }
    }()

    private static func collapseBlankLines(_ text: String) -> String {
        var result: [String] = []
        var blankRun = 0
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                blankRun += 1
                if blankRun == 1 { result.append("") }
            } else {
                blankRun = 0
                result.append(line)
            }
        }
        return result.joined(separator: "\n")
    }

    static func stripHTML(_ html: String) -> String {
        var text = html
        for pattern in htmlBlockPatterns {
            text = pattern.stringByReplacingMatches(
                in: text,
                range: NSRange(text.startIndex..., in: text),
                withTemplate: ""
            )
        }
        text = htmlBreakPattern.stringByReplacingMatches(
            in: text,
            range: NSRange(text.startIndex..., in: text),
            withTemplate: "\n"
        )
        text = htmlTagPattern.stringByReplacingMatches(
            in: text,
            range: NSRange(text.startIndex..., in: text),
            withTemplate: ""
        )
        for (entity, replacement) in htmlEntities {
            text = text.replacingOccurrences(of: entity, with: replacement)
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let htmlBlockPatterns: [NSRegularExpression] = {
        let sources = [
            #"<script\b[^>]*>[\s\S]*?</script>"#,
            #"<style\b[^>]*>[\s\S]*?</style>"#,
            #"<head\b[^>]*>[\s\S]*?</head>"#,
            #"<!--[\s\S]*?-->"#,
        ]
        return sources.map { try! NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }
    }()

    private static let htmlBreakPattern = try! NSRegularExpression(
        pattern: #"<(br|/p|/div|/li|/tr|/h[1-6])\b[^>]*>"#,
        options: [.caseInsensitive]
    )

    private static let htmlTagPattern = try! NSRegularExpression(pattern: #"<[^>]+>"#)

    private static let htmlEntities: [(String, String)] = [
        ("&nbsp;", " "), ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"),
        ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"), ("&#160;", " "),
    ]

    /// "I’m asking you to review the draft" → "Review the draft." The model
    /// announces most requests this way however it is instructed, and the
    /// announcement is the least informative part of a line that has room for
    /// about a dozen words. Still the sender's voice — it is what the sender
    /// asked for, minus the throat-clearing. Only the opening is touched.
    static func withoutAnnouncement(_ line: String) -> String {
        let range = NSRange(line.startIndex..., in: line)
        guard let match = announcementPattern.firstMatch(in: line, range: range),
              let matched = Range(match.range, in: line)
        else { return line }
        let rest = line[matched.upperBound...].trimmingCharacters(in: .whitespaces)
        guard let first = rest.first else { return line }
        return first.uppercased() + rest.dropFirst()
    }

    private static let announcementPattern = try! NSRegularExpression(
        pattern: #"^I(?:’|')?m (?:asking (?:you to|that you)|writing to (?:ask you to|let you know that|say that)?|sharing that|letting you know that)\s+|^I wanted to (?:let you know that|share that|ask you to)\s+|^I just wanted to (?:let you know that|share that)\s+"#,
        options: [.caseInsensitive]
    )

    /// On some long bodies the model answers with a made-up tool invocation —
    /// `tool: extract_text("May it please the Court…")` was seen on a legal
    /// brief — instead of a sentence. That is not a summary and must never
    /// reach a row.
    static func looksLikeToolCall(_ line: String) -> Bool {
        toolCallPattern.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil
    }

    private static let toolCallPattern = try! NSRegularExpression(
        pattern: #"^\s*(?:(?:tool|function|call|action)\s*[:=]|(?:(?:tool|function|call|action)\s+)?[A-Za-z_][A-Za-z0-9_.]*\s*\((?:\s*["']|\s*[A-Za-z_]+\s*[:=]))"#,
        options: [.caseInsensitive]
    )

    /// The model's reply, made fit for one line: first sentence-bearing line,
    /// no wrapping quotes, no "Summary:" prefix, capped in length. Returns
    /// `nil` for a reply with nothing in it, so the caller can treat that as a
    /// failure rather than show a blank line as if it were an answer.
    static func cleaned(_ response: String) -> String? {
        let lines = response
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard var line = lines.first, !looksLikeToolCall(line) else { return nil }
        for prefix in ["Summary:", "summary:", "- ", "• ", "* "] where line.hasPrefix(prefix) {
            line = String(line.dropFirst(prefix.count))
        }
        line = line.trimmingCharacters(in: .whitespaces)
        let quotes: Set<Character> = ["\"", "“", "”", "'", "‘", "’"]
        if let first = line.first, let last = line.last, first != last || line.count > 1,
           quotes.contains(first), quotes.contains(last) {
            line = String(line.dropFirst().dropLast())
        }
        line = line.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        line = withoutAnnouncement(line)
        guard !line.isEmpty else { return nil }
        if line.count > maximumSummaryLength {
            let cut = line.index(line.startIndex, offsetBy: maximumSummaryLength - 1)
            line = String(line[..<cut]).trimmingCharacters(in: .whitespaces) + "…"
        }
        return line
    }
}

// MARK: - Sidecar

/// One remembered summary. `receivedAt` is what pruning keys on: a summary
/// outlives its message's stay in the window by a little, so widening the
/// window does not re-summarize what was already done.
nonisolated struct MailSummaryEntry: Codable, Sendable, Equatable {
    var id: Int64
    var receivedAt: Date
    var summary: String
}

/// Every summary produced for one source, kept on disk so a relaunch paints
/// them with the cached envelopes instead of running the model over the
/// window again.
///
/// A sidecar, not Core Data, under the same rule as the envelope cache: the
/// store is CloudKit-bound with one writer, and these are derived from a
/// foreign feed. Local, whole-file, and ignored if the source id differs.
nonisolated struct MailSummaryRecord: Codable, Sendable, Equatable {
    var sourceID: String
    var entries: [MailSummaryEntry]
}

nonisolated struct MailSummaryStore: Sendable {
    private let file: MailSidecarFile

    static let disabled = MailSummaryStore(file: .disabled)

    static var live: MailSummaryStore {
        MailSummaryStore(file: .inApplicationSupport(named: "mail-summaries.json"))
    }

    static func temporary() -> MailSummaryStore {
        MailSummaryStore(file: .temporary(prefix: "PlannerMailSummaries"))
    }

    init(file: MailSidecarFile) {
        self.file = file
    }

    func load() -> MailSummaryRecord? { file.load() }

    func save(_ record: MailSummaryRecord) { file.save(record) }
}
