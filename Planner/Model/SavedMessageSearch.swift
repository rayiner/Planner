import Foundation

nonisolated enum SavedMessageSearch {
    static let searchableKeys = ["subject", "senderName", "senderAddress", "body"]

    static func tokens(in raw: String) -> [String] {
        raw.split { $0.isWhitespace || $0.isNewline }
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    /// NSPredicate `.contains` is `LIKE *rhs*`. Escape LIKE metacharacters
    /// before binding. Order matters: `\` first.
    static func escapedContainsToken(_ token: String) -> String {
        token
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "*", with: "\\*")
            .replacingOccurrences(of: "?", with: "\\?")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }

    static func tokenPredicate(_ token: String) -> NSPredicate {
        let escaped = escapedContainsToken(token)
        // `.contains` treats `\` as data, so `foo\*bar` matches no row.
        // LIKE `*escaped*` is the wrapper CONTAINS is documented as.
        return NSCompoundPredicate(orPredicateWithSubpredicates: searchableKeys.map { key in
            NSComparisonPredicate(
                leftExpression: NSExpression(forKeyPath: key),
                rightExpression: NSExpression(forConstantValue: "*\(escaped)*"),
                modifier: .direct,
                type: .like,
                options: [.caseInsensitive, .diacriticInsensitive]
            )
        })
    }
}
