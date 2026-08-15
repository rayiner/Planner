import Foundation

/// Reconciles a series' expansion with the records Outlook stores separately
/// for slots that were individually moved, edited, or deleted.
///
/// Two different things retire a generated slot, and both arrive as a bare
/// date: an **exception** record that replaces it (listed on its own, at its
/// real time) and an **EXDATE** marking it deleted outright. They are claimed
/// through the same mechanism.
nonisolated enum OutlookExceptions {
    /// A well-formed `recurrence id` matches its slot to the second; this is
    /// slack for clock skew, not for zone shifts.
    static let exactTolerance: TimeInterval = 60

    /// Ceiling on the fuzzy pass. Big enough to absorb a whole-day shift, small
    /// enough that a daily series still can't confuse neighbours.
    static let maxTolerance: TimeInterval = 26 * 3600

    /// How far a claim may sit from a slot and still take it.
    ///
    /// Never more than half the gap between neighbouring occurrences, so a
    /// shifted id can never be mistaken for the slot next door.
    static func tolerance(for occurrences: [OutlookRecurrence.Occurrence]) -> TimeInterval {
        var smallestGap = TimeInterval.infinity
        for index in 1..<max(1, occurrences.count) where index < occurrences.count {
            let gap = occurrences[index].start.timeIntervalSince(occurrences[index - 1].start)
            smallestGap = min(smallestGap, abs(gap))
        }
        guard smallestGap.isFinite else { return maxTolerance }
        return min(maxTolerance, smallestGap / 2)
    }

    /// Drops the occurrences that a claim already accounts for.
    ///
    /// Exact matches are resolved first, across **every** claim, before any
    /// fuzzy matching happens. That ordering is what keeps a well-formed id
    /// from losing its own slot to a shifted neighbour that happened to be
    /// processed earlier.
    static func removeSuperseded(
        _ occurrences: [OutlookRecurrence.Occurrence],
        claims: [Date]
    ) -> [OutlookRecurrence.Occurrence] {
        guard !claims.isEmpty, !occurrences.isEmpty else { return occurrences }

        let limit = tolerance(for: occurrences)
        var taken = Set<Int>()
        var unclaimed = Array(claims.indices)

        // Pass 1: exact.
        unclaimed = unclaimed.filter { index in
            !claim(claims[index], in: occurrences, taken: &taken, within: exactTolerance)
        }
        // Pass 2: everything that did not land exactly.
        for index in unclaimed {
            _ = claim(claims[index], in: occurrences, taken: &taken, within: limit)
        }

        return occurrences.enumerated()
            .filter { !taken.contains($0.offset) }
            .map(\.element)
    }

    /// Takes the nearest not-yet-claimed occurrence within `limit`, if any.
    private static func claim(
        _ time: Date,
        in occurrences: [OutlookRecurrence.Occurrence],
        taken: inout Set<Int>,
        within limit: TimeInterval
    ) -> Bool {
        var best: Int?
        var bestDelta = TimeInterval.infinity
        for (index, occurrence) in occurrences.enumerated() where !taken.contains(index) {
            let delta = abs(time.timeIntervalSince(occurrence.start))
            if delta <= limit, delta < bestDelta {
                best = index
                bestDelta = delta
            }
        }
        guard let best else { return false }
        taken.insert(best)
        return true
    }
}
