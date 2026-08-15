import AppKit

/// Bulleted or numbered. Marker glyphs cycle by depth, like Notes.
enum NoteListKind {
    case bullet
    case numbered

    static let bulletFormats: [NSTextList.MarkerFormat] = [.disc, .circle, .square]
    static let numberedFormats: [NSTextList.MarkerFormat] = [.decimal, .lowercaseAlpha, .lowercaseRoman]

    var formats: [NSTextList.MarkerFormat] {
        self == .bullet ? Self.bulletFormats : Self.numberedFormats
    }

    /// `level` is 1-based; deeper levels cycle back through the glyphs.
    func list(forLevel level: Int) -> NSTextList {
        NSTextList(markerFormat: formats[max(0, level - 1) % formats.count], options: 0)
    }

    static func kind(of list: NSTextList) -> NoteListKind {
        numberedFormats.contains(list.markerFormat) ? .numbered : .bullet
    }
}

/// List structure is carried **entirely** by `NSParagraphStyle.textLists`, which
/// holds the nesting stack (outermost first).
///
/// TextKit draws the markers itself from that attribute, including numbering —
/// nested levels restart and the parent level resumes on its own. So this code
/// never writes marker characters into the text; doing so produces two markers
/// per line, which is exactly what an earlier attempt here did. It also means
/// there is no renumbering pass to maintain, and the plain-text shadow stays
/// free of marker punctuation.
///
/// Everything is written against `NSMutableAttributedString` rather than a text
/// view so it can be tested directly.
enum NoteListEditing {
    // MARK: - Reading

    static func lists(inParagraphAt location: Int, of storage: NSAttributedString) -> [NSTextList] {
        guard storage.length > 0 else { return [] }
        let index = min(location, storage.length - 1)
        let style = storage.attribute(.paragraphStyle, at: index, effectiveRange: nil) as? NSParagraphStyle
        return style?.textLists ?? []
    }

    static func kind(inParagraphAt location: Int, of storage: NSAttributedString) -> NoteListKind? {
        guard let innermost = lists(inParagraphAt: location, of: storage).last else { return nil }
        return NoteListKind.kind(of: innermost)
    }

    static func paragraphRanges(of storage: NSAttributedString, covering range: NSRange) -> [NSRange] {
        let text = storage.string as NSString
        guard text.length > 0 else { return [NSRange(location: 0, length: 0)] }

        var ranges: [NSRange] = []
        var location = min(range.location, text.length - 1)
        let end = min(NSMaxRange(range), text.length)
        repeat {
            let paragraph = text.paragraphRange(for: NSRange(location: location, length: 0))
            ranges.append(paragraph)
            location = NSMaxRange(paragraph)
        } while location < end
        return ranges
    }

    /// A paragraph's text without its trailing newline.
    static func contentRange(inParagraph paragraph: NSRange, of storage: NSAttributedString) -> NSRange {
        let text = storage.string as NSString
        var length = paragraph.length
        if length > 0,
           text.substring(with: NSRange(location: paragraph.location + length - 1, length: 1)) == "\n" {
            length -= 1
        }
        return NSRange(location: paragraph.location, length: max(0, length))
    }

    static func isEmptyListItem(paragraph: NSRange, in storage: NSAttributedString) -> Bool {
        guard !lists(inParagraphAt: paragraph.location, of: storage).isEmpty else { return false }
        return contentRange(inParagraph: paragraph, of: storage).length == 0
    }

    // MARK: - Editing

    /// Turns the selected paragraphs into a list of `kind`, converts them if they
    /// are already a list of the other kind, or strips the list if they all match.
    static func toggle(
        _ kind: NoteListKind,
        in storage: NSMutableAttributedString,
        selection: NSRange
    ) {
        let paragraphs = paragraphRanges(of: storage, covering: selection)
        // Qualified: the `kind` parameter shadows the lookup of the same name.
        let allMatch = paragraphs.allSatisfy {
            NoteListEditing.kind(inParagraphAt: $0.location, of: storage) == kind
        }

        for paragraph in paragraphs {
            let existing = lists(inParagraphAt: paragraph.location, of: storage)
            if allMatch {
                apply(lists: [], to: paragraph, in: storage)
            } else if existing.isEmpty {
                apply(lists: [kind.list(forLevel: 1)], to: paragraph, in: storage)
            } else {
                // Keep the depth, change the kind at every level.
                apply(lists: (1...existing.count).map { kind.list(forLevel: $0) }, to: paragraph, in: storage)
            }
        }
    }

    /// Indent or outdent. Outdenting past level 1 leaves the list entirely.
    static func changeDepth(
        by delta: Int,
        in storage: NSMutableAttributedString,
        selection: NSRange
    ) {
        for paragraph in paragraphRanges(of: storage, covering: selection) {
            let existing = lists(inParagraphAt: paragraph.location, of: storage)
            guard !existing.isEmpty else { continue }

            let target = existing.count + delta
            if target < 1 {
                apply(lists: [], to: paragraph, in: storage)
                continue
            }
            let depth = min(target, NoteFormatting.maximumListDepth)
            guard depth != existing.count else { continue }

            let kind = NoteListKind.kind(of: existing[existing.count - 1])
            var lists = existing
            if depth < existing.count {
                lists = Array(existing.prefix(depth))
            } else {
                while lists.count < depth {
                    lists.append(kind.list(forLevel: lists.count + 1))
                }
            }
            apply(lists: lists, to: paragraph, in: storage)
        }
    }

    /// Attribute-only: the text is never touched, so ranges stay valid and the
    /// caret does not move.
    private static func apply(
        lists: [NSTextList],
        to paragraph: NSRange,
        in storage: NSMutableAttributedString
    ) {
        guard storage.length > 0, paragraph.length > 0 else { return }
        let range = NSIntersectionRange(paragraph, NSRange(location: 0, length: storage.length))
        guard range.length > 0 else { return }
        storage.addAttribute(.paragraphStyle, value: NoteFormatting.paragraphStyle(for: lists), range: range)
    }
}
