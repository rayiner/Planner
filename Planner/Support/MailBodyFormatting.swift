import AppKit

/// Turns a message body into what the reading pane can safely show.
///
/// HTML is decoded through `NSAttributedString`'s HTML document type — the
/// same path notes use for a paste from Safari — then run through
/// `NoteFormatting.sanitized` so the allowlist is one list: bold, italic,
/// underline, lists and links. Scripts, images and remote resources are
/// stripped *before* the parse, because the HTML importer will otherwise
/// fetch `src` URLs (tracking pixels included).
enum MailBodyFormatting {
    static func attributedString(html: String?, plain: String) -> NSAttributedString {
        if let html, let decoded = decodeHTML(html) {
            return NoteFormatting.sanitized(decoded)
        }
        return NSAttributedString(string: plain, attributes: NoteFormatting.typingAttributes)
    }

    static func decodeHTML(_ html: String) -> NSAttributedString? {
        let cleaned = stripUnsafe(html)
        guard !cleaned.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let data = cleaned.data(using: .utf8)
        else { return nil }
        return try? NSAttributedString(
            data: data,
            options: [
                .documentType: NSAttributedString.DocumentType.html,
                .characterEncoding: String.Encoding.utf8.rawValue,
            ],
            documentAttributes: nil
        )
    }

    /// Tags and attributes the HTML importer would honour by loading them.
    static func stripUnsafe(_ html: String) -> String {
        var result = html
        for pattern in Self.blockPatterns {
            result = pattern.stringByReplacingMatches(
                in: result,
                range: NSRange(result.startIndex..., in: result),
                withTemplate: ""
            )
        }
        return result
    }

    private static let blockPatterns: [NSRegularExpression] = {
        let sources = [
            #"<script\b[^>]*>[\s\S]*?</script>"#,
            #"<style\b[^>]*>[\s\S]*?</style>"#,
            #"<iframe\b[^>]*>[\s\S]*?</iframe>"#,
            #"<object\b[^>]*>[\s\S]*?</object>"#,
            #"<embed\b[^>]*/?>"#,
            #"<img\b[^>]*/?>"#,
            #"<svg\b[^>]*>[\s\S]*?</svg>"#,
            #"<video\b[^>]*>[\s\S]*?</video>"#,
            #"<audio\b[^>]*>[\s\S]*?</audio>"#,
            #"<form\b[^>]*>[\s\S]*?</form>"#,
            #"<link\b[^>]*>"#,
            #"<base\b[^>]*>"#,
            #"<meta\b[^>]*>"#,
            #"\sstyle\s*=\s*("[^"]*"|'[^']*')"#,
            #"\sbackground\s*=\s*("[^"]*"|'[^']*')"#,
        ]
        return sources.map {
            try! NSRegularExpression(pattern: $0, options: [.caseInsensitive])
        }
    }()
}
