import AppKit

/// Conversion and sanitising for note text.
///
/// Notes support bold, italic, underline, lists and hyperlinks — and
/// deliberately nothing else. That constraint is enforced **on input**, not by
/// withholding commands: pasted text from a browser arrives with fonts, sizes
/// and colours, so everything entering the buffer goes through `sanitized(_:)`.
enum NoteFormatting {
    static let bodyFontSize: CGFloat = 13

    static var bodyFont: NSFont { .systemFont(ofSize: bodyFontSize) }

    /// Indent applied per level of list nesting.
    static let indentPerLevel: CGFloat = 20

    /// Attributes for freshly typed text.
    static var typingAttributes: [NSAttributedString.Key: Any] {
        [.font: bodyFont, .foregroundColor: NSColor.labelColor]
    }

    // MARK: - Store <-> attributed

    /// Rebuilds the note. `rtf` wins when present; `plain` covers rows written
    /// before rich text existed, and rows whose RTF failed to decode.
    static func attributedString(rtf: Data?, plain: String?) -> NSAttributedString {
        if let rtf, !rtf.isEmpty,
           let decoded = NSAttributedString(rtf: rtf, documentAttributes: nil) {
            return sanitized(decoded)
        }
        return sanitized(NSAttributedString(string: plain ?? "", attributes: typingAttributes))
    }

    /// RTF for storage, or nil when the note is empty — an empty note is `nil`
    /// in both columns rather than an empty attributed string.
    static func rtf(from attributed: NSAttributedString) -> Data? {
        guard !attributed.string.isEmpty else { return nil }
        return attributed.rtf(
            from: NSRange(location: 0, length: attributed.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
        )
    }

    /// The plain-text shadow stored alongside the RTF.
    static func plainText(from attributed: NSAttributedString) -> String? {
        attributed.string.isEmpty ? nil : attributed.string
    }

    // MARK: - Traits

    /// Bold and italic are carried as font traits, so toggling one is a font
    /// substitution at the same family and size — never a size or family change.
    static func font(_ font: NSFont, setting trait: NSFontDescriptor.SymbolicTraits, on: Bool) -> NSFont {
        var traits = font.fontDescriptor.symbolicTraits
        if on { traits.insert(trait) } else { traits.remove(trait) }
        let descriptor = bodyFont.fontDescriptor.withSymbolicTraits(traits)
        return NSFont(descriptor: descriptor, size: bodyFontSize) ?? bodyFont
    }

    static func hasTrait(_ trait: NSFontDescriptor.SymbolicTraits, _ font: NSFont?) -> Bool {
        font?.fontDescriptor.symbolicTraits.contains(trait) ?? false
    }

    // MARK: - Sanitising

    /// Keeps bold, italic, underline and list structure. Everything else is
    /// dropped and the font is forced back to the app body font, so no pasted
    /// size, family or colour can survive.
    static func sanitized(_ input: NSAttributedString) -> NSAttributedString {
        let output = NSMutableAttributedString(string: input.string)
        let whole = NSRange(location: 0, length: input.length)
        guard input.length > 0 else { return output }

        output.beginEditing()
        input.enumerateAttributes(in: whole, options: []) { attributes, range, _ in
            output.setAttributes(sanitizedAttributes(attributes), range: range)
        }
        // HTML and RTFD can carry attachments; the attribute is dropped above,
        // but the placeholder character it hangs on must go too or the note
        // keeps an invisible box where the image was.
        output.mutableString.replaceOccurrences(
            of: "\u{fffc}",
            with: "",
            options: [],
            range: NSRange(location: 0, length: output.length)
        )
        output.endEditing()
        return output
    }

    private static func sanitizedAttributes(
        _ attributes: [NSAttributedString.Key: Any]
    ) -> [NSAttributedString.Key: Any] {
        var kept: [NSAttributedString.Key: Any] = [
            .font: font(preservingTraitsOf: attributes[.font] as? NSFont),
            .foregroundColor: NSColor.labelColor,
        ]

        // Underline survives, but only as a plain single rule.
        if let underline = attributes[.underlineStyle] as? Int, underline != 0 {
            kept[.underlineStyle] = NSUnderlineStyle.single.rawValue
        }

        // Hyperlinks survive, normalised to a URL: a planner note is where
        // ticket and meeting links land. Their appearance comes from the text
        // view's link attributes, never from a stored colour.
        if let link = attributes[.link] {
            if let url = link as? URL {
                kept[.link] = url
            } else if let string = link as? String, let url = URL(string: string) {
                kept[.link] = url
            }
        }

        if let paragraph = attributes[.paragraphStyle] as? NSParagraphStyle {
            kept[.paragraphStyle] = sanitizedParagraphStyle(paragraph)
        }
        return kept
    }

    /// Bold and italic are carried by font traits, so read the traits off the
    /// incoming font and re-apply them to the app font at the app size.
    private static func font(preservingTraitsOf incoming: NSFont?) -> NSFont {
        guard let incoming else { return bodyFont }
        let traits = incoming.fontDescriptor.symbolicTraits
        var descriptor = bodyFont.fontDescriptor
        var wanted: NSFontDescriptor.SymbolicTraits = []
        if traits.contains(.bold) { wanted.insert(.bold) }
        if traits.contains(.italic) { wanted.insert(.italic) }
        guard !wanted.isEmpty else { return bodyFont }
        descriptor = descriptor.withSymbolicTraits(wanted)
        return NSFont(descriptor: descriptor, size: bodyFontSize) ?? bodyFont
    }

    /// Only list structure survives. Indents are **recomputed from the nesting
    /// depth** rather than trusted, so pasted list items line up with typed ones.
    private static func sanitizedParagraphStyle(_ incoming: NSParagraphStyle) -> NSParagraphStyle {
        paragraphStyle(for: Array(incoming.textLists.prefix(maximumListDepth)))
    }

    /// The one place a note's paragraph style is built. Indent and the marker's
    /// tab stop are both derived from depth, so the sanitiser and the list editor
    /// cannot disagree about what a level-N item looks like.
    static func paragraphStyle(for lists: [NSTextList]) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        guard !lists.isEmpty else { return style }

        style.textLists = lists
        let depth = CGFloat(lists.count)
        style.headIndent = depth * indentPerLevel
        style.firstLineHeadIndent = max(0, (depth - 1) * indentPerLevel)
        // The marker is followed by a tab; this stop is where the content lands.
        style.tabStops = [NSTextTab(textAlignment: .left, location: style.headIndent, options: [:])]
        style.defaultTabInterval = indentPerLevel
        return style
    }

    /// Nesting is capped so marker cycling and indentation stay sane.
    static let maximumListDepth = 5
}
