import XCTest
@testable import Planner

/// Ported from the suppression half of CalendarList's `recurrence.test.js`.
///
/// The subtlety these guard is that a `recurrence id` is not always exact:
/// Outlook occasionally reports one shifted by a timezone or DST offset, so
/// matching is nearest-wins within a tolerance rather than by equality.
final class OutlookExceptionTests: XCTestCase {
    private typealias F = OutlookFixtures

    private func tuesdays() -> [OutlookRecurrence.Occurrence] {
        F.expand(
            F.master(
                F.at(2026, 1, 6, 10, 0),
                OutlookRecurrenceRule(pattern: .weekly, daysOfWeek: F.mask("0010000"))
            ),
            from: F.at(2026, 1, 1),
            to: F.at(2026, 2, 1)
        )
    }

    private func dailyWeek() -> [OutlookRecurrence.Occurrence] {
        F.expand(
            F.master(F.at(2026, 1, 5, 9, 0), OutlookRecurrenceRule(pattern: .daily)),
            from: F.at(2026, 1, 5),
            to: F.at(2026, 1, 9, 23, 59)
        )
    }

    func testAnExceptionSuppressesTheSlotItCameFrom() {
        let kept = OutlookExceptions.removeSuperseded(
            tuesdays(),
            claims: [F.at(2026, 1, 13, 10, 0)]
        )
        XCTAssertEqual(F.days(kept), ["2026-01-06", "2026-01-20", "2026-01-27"])
    }

    func testARecurrenceIdShiftedByADayAndAnHourStillMatchesItsSlot() {
        let occurrences = F.expand(
            F.master(
                F.at(2026, 1, 6, 19, 30),
                OutlookRecurrenceRule(pattern: .weekly, daysOfWeek: F.mask("0010000"))
            ),
            from: F.at(2026, 1, 1),
            to: F.at(2026, 2, 1)
        )
        let kept = OutlookExceptions.removeSuperseded(
            occurrences,
            claims: [F.at(2026, 1, 12, 20, 30)]
        )
        XCTAssertEqual(F.days(kept), ["2026-01-06", "2026-01-20", "2026-01-27"])
    }

    /// Tolerance is capped at half the gap between neighbours, so one id can
    /// never swallow the slot next door as well as its own.
    func testAShiftedIdInADailySeriesClaimsOneSlotNeverTwo() {
        let occurrences = dailyWeek()
        XCTAssertEqual(occurrences.count, 5)
        let kept = OutlookExceptions.removeSuperseded(
            occurrences,
            claims: [F.at(2026, 1, 6, 22, 0)]
        )
        XCTAssertEqual(kept.count, 4)
    }

    /// The case that actually pins the two-pass ordering down.
    ///
    /// In a *uniform* series it cannot: tolerance is capped at half the gap, so
    /// no claim can ever reach two slots and the outcome is the same whichever
    /// pass runs first. (The ported case below has that weakness — it passes
    /// even with the exact pass deleted.) An **uneven** series is different:
    /// Mon+Wed has a smallest gap of two days, so the 24h tolerance spans a
    /// gap it was never sized for, and two claims can want one slot.
    ///
    /// Resolving exact matches first means every claim lands somewhere. Fuzzy
    /// first lets the shifted claim take the exact one's slot and then strand
    /// the exact claim, retiring one occurrence instead of two.
    func testExactMatchesResolveFirstSoEveryClaimLandsSomewhere() {
        let occurrences = F.expand(
            F.master(
                F.at(2026, 3, 2, 9, 0),
                OutlookRecurrenceRule(pattern: .weekly, daysOfWeek: F.mask("0101000"))   // Mon + Wed
            ),
            from: F.at(2026, 3, 1),
            to: F.at(2026, 3, 15)
        )
        XCTAssertEqual(F.days(occurrences), ["2026-03-02", "2026-03-04", "2026-03-09", "2026-03-11"])
        XCTAssertEqual(OutlookExceptions.tolerance(for: occurrences), 24 * 3600)

        let kept = OutlookExceptions.removeSuperseded(
            occurrences,
            claims: [
                F.at(2026, 3, 3, 9, 0),   // shifted: equidistant from Mar 2 and Mar 4
                F.at(2026, 3, 2, 9, 0),   // exact: Mar 2
            ]
        )
        XCTAssertEqual(
            F.days(kept), ["2026-03-09", "2026-03-11"],
            "the exact claim takes Mar 2, leaving the shifted one to retire Mar 4"
        )
    }

    /// Ported as-is from the JS corpus. Weaker than it looks — see the case
    /// above — but kept because it documents the intended behaviour.
    func testAnExactIdKeepsItsOwnSlotWhenAShiftedIdCompetesForIt() {
        let kept = OutlookExceptions.removeSuperseded(
            dailyWeek(),
            claims: [
                F.at(2026, 1, 6, 22, 0),   // listed first, nearest to Jan 7, but inexact
                F.at(2026, 1, 7, 9, 0),    // exact
            ]
        )
        XCTAssertFalse(F.days(kept).contains("2026-01-07"), "the exact id should have claimed Jan 7")
        XCTAssertEqual(
            kept.count, 4,
            "with Jan 7 taken, nothing sits within tolerance of the shifted id, so it drops out"
        )
    }

    func testEachExceptionClaimsAtMostOneSlot() {
        let kept = OutlookExceptions.removeSuperseded(
            tuesdays(),
            claims: [F.at(2026, 1, 13, 10, 0), F.at(2026, 1, 20, 10, 0)]
        )
        XCTAssertEqual(F.days(kept), ["2026-01-06", "2026-01-27"])
    }

    func testAClaimFarFromEverySlotSuppressesNothing() {
        let kept = OutlookExceptions.removeSuperseded(
            tuesdays(),
            claims: [F.at(2026, 6, 1, 10, 0)]
        )
        XCTAssertEqual(F.days(kept).count, 4)
    }

    func testNoClaimsLeavesTheExpansionUntouched() {
        let occurrences = tuesdays()
        XCTAssertEqual(
            OutlookExceptions.removeSuperseded(occurrences, claims: []),
            occurrences
        )
    }

    func testToleranceIsHalfTheSmallestGapAndCapped() {
        // Daily series: 24h gaps, so 12h.
        XCTAssertEqual(OutlookExceptions.tolerance(for: dailyWeek()), 12 * 3600)
        // Weekly series: half a week would be days, so the 26h cap applies.
        XCTAssertEqual(OutlookExceptions.tolerance(for: tuesdays()), OutlookExceptions.maxTolerance)
        // A single occurrence has no gap to measure.
        XCTAssertEqual(
            OutlookExceptions.tolerance(for: Array(tuesdays().prefix(1))),
            OutlookExceptions.maxTolerance
        )
        XCTAssertEqual(OutlookExceptions.tolerance(for: []), OutlookExceptions.maxTolerance)
    }
}
