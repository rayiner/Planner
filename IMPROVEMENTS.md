# Planner — Suggested Improvements

A code review of the full app as of branch `execute-plan/01f8b47f-pr-10-polish-reveal-highlight-empty-calendar` (2026-08-14). The whole test suite passes, and the big architectural decisions in DESIGN.md — ModelController as sole writer, did-save-driven outline, the recurrence engine, the coordinator's keep-stale semantics — are faithfully implemented and well tested. The findings below are what's left: six real bugs worth fixing before calling v1 done, a set of spec-vs-code divergences to resolve one way or the other, and a tail of performance, cleanup, and test-coverage work.

Every item was verified against the actual code, not just pattern-matched. Nothing here proposes reversing a decision DESIGN.md explicitly makes.

---

## 1. High-priority bugs

These six are user-visible correctness failures, ordered roughly by how often a user would hit them.

> **Status update (2026-08-14):** 1.1, 1.2, and 1.3 are fixed, each with regression tests (`MainSplitViewControllerTests` undo tests, `WeekCalendarViewTests`/`CalendarEventRenderingTests` in-place chip tests, `OutlookAgendaTests` all-day series tests). 1.4–1.6 remain open.

### 1.1 Undoing a create or delete never reaches the outline — and never saves ✅ FIXED

`OutlineViewController.swift:166-226`, `AppDelegate.swift:92-94`

The outline updates structure only from `NSManagedObjectContextDidSave` (per DESIGN §4.3), and its objects-did-change handler processes only updates/refreshes. Edit → Undo routes to `viewContext.undoManager`, which mutates the context in memory — but nothing observes `.NSUndoManagerDidUndoChange`/`.NSUndoManagerDidRedoChange` and saves, so the did-save notification the outline depends on never fires. Pressing ⌘Z after a delete visibly does nothing in the outline, while the calendar FRC (which reacts to objects-did-change) resurrects the chip — the two panes disagree. The undone state also sits unsaved until quit; a crash loses it. DESIGN §4.8 explicitly names undo as the recovery path for delete.

**Fix:** observe the undo/redo notifications on `viewContext.undoManager` (in `AppDelegate` or `MainSplitViewController`) and call `persistence.saveViewContext(...)`. The resulting did-save drives the existing outline machinery — no change to the did-save architecture needed.

### 1.2 Calendar chips go stale when a task changes in place ✅ FIXED

`WeekCalendarView.swift:996-999`

`syncChipViews()` decides whether to rebuild chip views by comparing UUIDs only:

```swift
let chipsUnchanged = wantedChips.count == chipViews.count
    && zip(wantedChips, chipViews).allSatisfy { $0.uuid == $1.chip.uuid }
```

`DeadlineChipView` holds an immutable `chip` and draws title/strikethrough/dimming from it. Completing or renaming a task flows correctly all the way to `weekView.deadlines` — and then stops here, because the UUID set didn't change. The chip doesn't dim, strike, or retitle until the chip set otherwise changes (paging, add/delete). The same applies to events (`$0.id == $1.chip.id`): a retitled Outlook event keeps its id, so its row and tooltip stay stale after a refresh.

**Fix:** compare full value equality (`$0 == $1.chip`), or keep UUID identity for view reuse but push the new struct into the existing view (`var chip` with `didSet { needsDisplay = true; toolTip = …; setAccessibilityLabel(…) }`). Add a test that mutates a chip in place (same UUID, flipped `isCompleted`) and asserts the rendered state — the current tests only ever set `deadlines` once or change counts.

### 1.3 All-day recurring events land one day late ✅ FIXED

`OutlookAgenda.swift:52`, `OutlookRecurrence.swift:38, 266-273`

The half-day nudge that fixes Outlook's UTC-midnight all-day encoding is applied only *after* expansion, per occurrence. Expansion itself anchors on the raw `master.start`. For an all-day weekly-Saturday series stored at UTC midnight (arriving as Fri 20:00 US-Eastern): the anchor day is Friday, the rule mask says Saturday, so slots generate at Sat 20:00 — which the nudge then rounds to **Sunday**. Every occurrence, including the first, shifts a day. The same root cause hits `advanceDaily`'s mask check and `advanceAbsoluteMonthly`'s `dayOfMonth` (a day-31 series nudges onto the 1st). DESIGN §8.6.6 rule 6 says the nudge applies to `DTSTART;VALUE=DATE` as well as `UNTIL`; only the `UNTIL` half is implemented (`seriesEndBound`, `OutlookRecurrence.swift:58-63`).

**Fix:** when `master.isAllDay`, expand from a nudged anchor — `allDayBoundary(master.start)` — so occurrences land at local midnight and the per-occurrence nudge becomes a no-op for them. There is currently **no all-day recurring test anywhere**; add the Fri-20:00-ET weekly-Saturday case and an `absoluteMonthly` day-31 case (see §7).

### 1.4 The coordinator's 30s timeout cannot actually fire

`EventCoordinator.swift:153-169`, `OutlookEventSource.swift:57-65`

The timeout races the fetch in a `withThrowingTaskGroup` — but a throwing task group awaits all children before propagating, and the fetch child is a `withCheckedThrowingContinuation` wrapping a synchronous Apple-event call that never observes cancellation. So the timeout error is delivered only when the fetch itself returns (up to the source's own 120-second Apple-event timeout, `OutlookScripting.timeoutTicks`), and never for a truly hung Outlook. This defeats the one liveness guarantee the design leans on ("a hung spinner is unrecoverable", DESIGN §8.6.8). Note the coordinator's 30s is silently dominated by the source's 120s even in the best case.

**Fix:** drop the task group. Run the fetch in an unstructured `Task` and start a parallel 30s timer that, if the state is still `.loading` and the generation unchanged, sets `.failed(.timedOut)`. The existing generation gate already handles the real result arriving later. This also makes the path testable — it currently has zero coverage.

### 1.5 A failed Apple event mid-fetch blanks the grid as a "success"

`OutlookEventSource.swift:237-240`, `OutlookError.swift:15, 48-49`

When an underlying Apple event fails (timeout −1712, Outlook busy or quitting, consent revoked mid-run), `propertyDictionaries` and `filtered(...)` just return empty — no `lastError`/delegate check exists — so `fetch` returns `[]`, the coordinator enters `.loaded`, and the user's events are erased until the next refresh. The keep-stale-on-failure rule (`EventCoordinator.swift:137-139`) only protects against *thrown* errors. Telling evidence: `OutlookError.appleEvent(code:)` exists with copy and a recovery suggestion but is never constructed in production — the error path it was written for was never wired.

**Fix:** set an `SBApplicationDelegate` (`eventDidFail(_:withError:)`) or check the last-error state after each of the three queries and the account/calendar reads; throw `.appleEvent(code:)` when a send failed. "Query failed" must be distinguishable from "query matched nothing."

### 1.6 First launch fires the TCC consent dialog

`OutlookEventSource.swift:97-99`, `CalendarViewController.swift:64`

`fetch` deliberately lets `.notDetermined` consent fall through, on the assumption that "a refresh is always user-initiated" — but `CalendarViewController.viewDidLoad` calls `events.refresh()` unconditionally at launch. With Outlook running and consent undetermined, the very first automatic refresh raises the system consent dialog at a moment the user didn't choose. DESIGN §8.6.4 specifies the opposite: preflight quietly at startup, prompt only on explicit refresh. The preflight (`automationPermission()`) exists but has no production caller outside `fetch`.

**Fix:** thread a `userInitiated: Bool` through `refresh()` (or preflight in `viewDidLoad`), and for non-user-initiated refreshes short-circuit on `.notDetermined` into the quiet status-view affordance instead of prompting.

---

## 2. Medium-priority correctness and robustness

**2.1 Calendars without an account can crash the fetch.** `OutlookEventSource.swift:171-174` does a KVC `value(forKey:)` on the calendar's `account` without the NSNull guard the decoder applies everywhere else. Outlook's "On My Computer" calendars have no account; `NSNull.value(forKey:)` raises an ObjC exception Swift can't catch, crashing the outlook queue on every refresh for such users. Guard `is NSNull` / cast to `SBObject` first.

**2.2 `NSCalendarDayChanged` isn't guaranteed main-thread delivery.** `EventCoordinator.swift:58-66` registers a selector targeting a `@MainActor` method and a comment asserts main-thread posting, but Apple documents no such guarantee and background delivery has been observed. Off-main delivery traps the isolation assertion — a once-a-day crash at midnight that's nearly undiagnosable from a report. Make the receiver `nonisolated` and hop: `Task { @MainActor in … }`.

**2.3 The calendar grid itself never handles day rollover.** The coordinator refreshes the *event window* on day change, but nothing re-applies the grid: `isToday` is baked into cells at configure time (`WeekCalendarView.swift:775`) and nothing redraws overdue chips. An app left open overnight highlights yesterday as today and doesn't turn newly overdue chips red. Observe `.NSCalendarDayChanged` (and `NSSystemClockDidChange`) in `CalendarViewController` and re-run `applyVisibleWeeks()` — fold this into the same fix as 2.2.

**2.4 Paste sanitization has an unsanitized escape hatch. ✅ FIXED (2026-08-15)** `NoteTextView.swift:345-363` tries `.rtf`, then `.string`, then falls through to `super.paste(sender)` — a pasteboard carrying only RTFD (or another rich flavor) bypasses `NoteFormatting.sanitized` entirely, violating the file's own invariant that a browser color/font never reaches the store. `readSelection` (:375-391) has the same shape. Decode RTFD too; for any other rich type insert the plain string — never `super.paste`.

> Fixed by restricting `readablePasteboardTypes` to RTF/HTML/plain (AppKit picks the flavor before `readSelection` runs, so per-type interception can't be airtight), decoding HTML through the sanitiser (browsers put no RTF on the pasteboard, so formatting used to be lost), and refusing undecodable content instead of falling through to `super`. Landed together with hyperlink support in the sanitiser (`.link` kept, normalised to URL — DESIGN §7A amended), attachment-placeholder stripping, a Return-with-selection fix in list key handling, and a visible save-failure indicator in the inspector. Regression tests in `NoteFormattingTests` (intake section) and `InspectorViewControllerTests`.

**2.5 `createSibling(of:)` hard-crashes on the corrupt state DESIGN plans to repair.** `ModelController.swift:77` hits `preconditionFailure` on a parentless task — exactly the state DESIGN §3.3 anticipates from a future CloudKit import and plans to *repair*, not crash on. Throw a `ModelError` case instead so a ⌘T on a broken row degrades rather than crashes.

**2.6 `setDayNote` mishandles duplicate DayNote rows.** DESIGN declares duplicates legal (CloudKit forbids uniqueness constraints), and the read path tie-breaks correctly — but the write path (`ModelController.swift:163-184`, `fetchLimit = 1` at :203-212) edits/deletes only the first row. Clearing the text deletes the oldest row and the surviving duplicate's stale text immediately becomes the day's note again: a clear that un-clears. Fetch all rows for the day, edit the tie-break winner, delete the rest.

**2.7 Every non-cancelled Outlook exception is labeled "Moved".** `OutlookAgenda.swift:66-78` hardcodes `isRescheduled: true`, so an occurrence whose only change was its subject gets the "Moved" tooltip tag and VoiceOver suffix. Compare the exception's start against its `recurrenceId` (the tolerance in `OutlookExceptions` already exists) and only tag genuine moves.

**2.8 `revealInspector` focuses the note before the collapsed pane is back in the window.** `MainSplitViewController.swift:397-404` uncollapses with an animator and immediately calls `focusNote()`; while collapsed, the text view can be out of the window, so `makeFirstResponder` fails silently and ⌘I's whole point — keyboard access to the note — is lost intermittently. Run `focusNote()` in the animation-group completion and guard on `notesTextView.window != nil`.

**2.9 `applySurgicalDeletes` has two latent hazards.** `OutlineViewController.swift:269-300`: (a) it reads relationships (`task.parentTask`) on objects from `NSDeletedObjectsKey` *after* the save — works while they're realized, but post-save deleted objects are allowed to become unfulfillable faults; snapshot the parent mapping before the delete. (b) The projects branch returns success while ignoring deleted tasks that aren't descendants of those projects — a single save deleting a project plus an unrelated task (batched undo, future multi-select) leaves a stale row whose item is a deleted object. Fall back to `reloadFromStore()` unless every deleted task's ancestry hits a deleted project.

**2.10 Menu/toolbar validation runs Core Data fetches on every autovalidation pass.** `MainSplitViewController.swift:325-328, 474-494`: `selectedOutlineNode` is a computed property doing up to two fetches, and `isCommandEnabled` for `newTask` evaluates it twice — up to four SQLite round-trips per event-loop tick, times every toolbar item. Cache the resolved node per `.node` selection change (invalidate on did-save), or at minimum bind it to a local inside `isCommandEnabled`.

---

## 3. Spec drift: code and DESIGN.md disagree

Each of these needs a decision — fix the code or amend the doc — because right now the record can't say which is intended.

| # | Divergence | Where |
|---|---|---|
| 3.1 | **No New Subtask command exists.** DESIGN §6.2/§6.3: ⌘T on a task creates a *sibling*, ⌘⇧T a subtask. Shipped: ⌘T creates a child; no `newSubtask:` selector anywhere; `createSibling` has zero shipping callers; the §2.2 toolbar table (Add Subtask) is stale. A nested task's sibling is only creatable by reselecting its parent. | `MainSplitViewController.swift:181-190`, `MainMenu.xib` |
| 3.2 | **Subtask undo name.** `createSubtask` sets action name "New Task"; DESIGN's undo table says "New Subtask". The Edit menu shows "Undo New Task" after ⌘⇧T-equivalent creation, and `ModelConstraintTests.swift:250-251` asserts the wrong name. | `ModelController.swift:62` |
| 3.3 | **Delete-confirmation copy.** Code says "…and all of its **tasks**?" for a task with descendants; DESIGN §4.8 says "**subtasks**". Test-locked at `MainSplitViewControllerTests.swift:281-288`. | `MainSplitViewController.swift:298-306` |
| 3.4 | **Notes format row.** DESIGN line 2088 still says "Plain `String` … Not rich text" while §7A and the shipped code are RTF-with-plain-shadow. | DESIGN.md |
| 3.5 | **§2.1 publisher table** still says a calendar day click "does **not** clear `selectedNodeUUID`", contradicting the exclusive-selection rule both the doc and the code implement. | DESIGN.md |
| 3.6 | **Entry point row** says `@main AppDelegate`; the code uses `main.swift` + a global. (See also 5.4.) | DESIGN.md, `AppDelegate.swift` |
| 3.7 | **§8.5 helper roster** lists `monthYearString` / `endOfMonth` / `daysInMonthGrid`, which are now dead code (see 5.1). §8.1 still describes the month badge as "accent-tinted"; the code deliberately uses small-caps secondary text. §8.6.9 says event labels "carry a time prefix", contradicting the same section's "no time at all" and the code. §10's claim of a checked-in JSON `properties` fixture is false — payloads are synthesized in Swift for privacy (a fine decision worth recording). | DESIGN.md |

A single doc-pass PR closing 3.4–3.7 plus a decision on 3.1–3.3 would make DESIGN.md trustworthy again as the spec of record.

---

## 4. Performance

None of these are architectural; they're all "expensive thing in a hot path called more often than it looks."

**4.1 `DateFormatter` allocated per call in per-row/per-cell paths.** The pattern recurs across the codebase: `shortDeadlineString` (`Calendar+Month.swift:113-121`, called per deadline row on every outline reload — and reloads happen on every save, including each 0.4s note flush), `DayCellView.configure` (`WeekCalendarView.swift:789-793`, up to 56 cells per page turn), `monthName` (:58-65), `weekRangeComponents` (two formatters per call), `pushDay` (`InspectorViewController.swift`), and `updateEventStatus` (`MainSplitViewController.swift:267`). `DateFormatter` construction is milliseconds-scale. Cache them statically — `EventLabels.timeFormatter()` (`EventLabels.swift:72-84`) already demonstrates the house pattern; apply it everywhere.

**4.2 Allocations inside `draw(_:)`.** `DeadlineChipView.draw` (:1287-1307) and `EventRowView.draw` (:1366-1381) build paragraph styles, attribute dictionaries, and attributed strings on every redraw of every chip. Cache the paragraph style statically and the attributed string per (title, state).

**4.3 Day-notes refetched on every save of anything.** `CalendarViewController.swift:110-112` runs `applyDayNotes()` (a fetch plus full grid reassignment) on every did-save, including each note debounce flush and every rename. Filter the notification's userInfo for `DayNote` instances first.

**4.4 The deadline fetch the app ships isn't the one the tests test.** `ModelController.tasks(deadlineInWeeksFrom:)` and friends (:268-277, :337-346) have zero app callers — `CalendarViewController.swift:67-86` builds its own byte-identical `NSFetchRequest` for the FRC, and `DeadlineFetchTests` exercises only the unused copy. The two can drift silently (imagine one gaining an `isCompleted` filter). Add `ModelController.deadlineFetchRequest(from:to:)` and have both the FRC and the test-facing API consume it — this also honors DESIGN's "lookups go through ModelController" rule.

**4.5 Redundant recomputation in the cell layout path.** `visibleRows` (greedy fill, :805-833) is recomputed ~5× per layout pass per cell; the `deadlines`/`events` didSets (:77-85) have no equality guard and trigger two full `applyChipsToCells` passes per refresh. Small absolute cost, but caching `visibleRows` once per pass removes the risk of the five call sites drifting.

---

## 5. Dead code and maintainability

**5.1 The month-grid migration left a trail.** `MonthCalendarView.swift` is deleted, but `endOfMonth`, `monthYearString`, `daysInMonthGrid` (`Calendar+Month.swift:11-22, 123-132`) have zero callers; `startOfMonth` and `ModelController.tasks(deadlineInMonthOf:)` are kept alive only by one civil-month test. `daysInMonthGrid` additionally uses locale `firstWeekday`, contradicting the hardcoded-Monday decision — a trap for whoever reuses it. Delete all of it, drop the civil-month test, and consider renaming the file `Calendar+Week.swift` while touching it.

**5.2 Two decoders for the recurrence end rule.** `OutlookRecurrenceRule.End.code(_:data:)` (:80-91) reimplements `OutlookRecordDecoder.endRule` (:97-112) with subtly different NSNull tolerance and has zero production callers. Delete it and point its tests at `endRule`.

**5.3 `WeekCalendarView.swift` is 1,392 lines holding six types plus ~330 lines of test hooks.** `DayCellView`, `DeadlineChipView`, and `EventRowView` are `private` only because they share the file; the seams are clean closure callbacks. Split into `DayCellView.swift`, `CalendarChipViews.swift`, and a `WeekCalendarView+TestHooks.swift`. Decomposition only — no design change.

**5.4 Entry-point confusion.** `AppDelegate.running` (:4-18) is written and never read; `main.swift`'s global already provides the keep-alive its comment describes; the doc comment still talks about `@main`. Two keep-alive mechanisms with comments pointing at a third confuse the next reader about which is load-bearing. Delete `Self.running`, fix the comments (and DESIGN, see 3.6).

**5.5 `failNextSave` ships in the release binary.** `PersistenceController.swift:64-74` is a test-only hook that adds an extra save path (silent rollback, no alert) to production. Wrap in `#if DEBUG`.

**5.6 Small duplications.** `objects(in:key:)` exists verbatim in `OutlineViewController` (:311) and `InspectorViewController` (:624) — extract a `Notification` helper; `reveal`'s stale-cache retry (:339-343) re-implements `reloadFromStore` minus one line. `OutlookAgenda.build`'s final sort (:80-85) is dead work whose key order *differs* from the canonical `CalendarEventChip.index` comparator — drop it or unify the comparator. `overlaps` takes an unused `calendar` parameter; `OutlookScripting.RecurrenceKey.startDate` is declared and never read.

**5.7 `setNote` lacks the no-change guard its sibling has.** `ModelController.swift:132-139` unconditionally rewrites, bumps `updatedAt`, and saves; `setDayNote` guards on equality. Callers currently pre-guard, but the API shouldn't rely on that — and meaningless `updatedAt` bumps matter once CloudKit last-writer-wins arrives.

---

## 6. Smaller fixes

- **`SelectionModel`'s nil-accepting setters are a footgun** (`SelectionModel.swift:47-53`): `selectNode(uuid: nil)` clears a selected *day* too, indistinguishable from `clearSelection()`. All current callers happen to be guarded; drop the nil overloads or make them side-conditional so the next un-guarded caller can't wipe the other pane's selection.
- **Occurrence-id collision** (`OutlookAgenda.swift:120-122`): a rescheduled exception moved onto a sibling occurrence's exact start second produces two events with identical ids (exceptions share the master's UID). Append the Outlook record id or an `|x` marker for exception-derived events.
- **Modifier keys leak into calendar navigation** (`WeekCalendarView.swift:168-176`): ⌘← moves the day selection like a plain arrow instead of reaching `super`. Guard on empty modifier flags. Same class of bug in the outline: ⌘Return/⌥Return start rename (`PlannerOutlineView.swift:35-43`).
- **The rename drag threshold is undermined** (`PlannerOutlineView.swift:30-33`): `mouseDragged` cancels the pending rename on *any* drag event, while the click handler deliberately tolerates 4pt of jitter. Apply `hasDraggedPastThreshold` before cancelling.
- **Overdue is invisible to VoiceOver** (`WeekCalendarView.swift:1269`): completed chips say ", Completed" but the red overdue treatment has no spoken counterpart. Add ", Overdue" — the events' ", Event" suffix already sets the parity precedent (§8.6.9).
- **`pushDay` gates on a rendered string** (`InspectorViewController.swift:506`): `caption != "Overdue"` breaks the moment the label is reworded or localized. Use `calendar.isOverdue(day)`, which already exists.
- **Rename suppresses all row reloads, with no catch-up** (`OutlineViewController.swift:302-309`): while any field editor is open, changes to *other* rows (inspector-driven completion, deadline) stay stale after the edit ends. Compare against the editing row, or reload skipped items in `endTitleEditing()`.
- **Tab/Shift-Tab asymmetry in note lists** (`NoteTextView.swift:213-227`): Tab indents only with an empty selection (a selection gets a literal tab); Shift-Tab outdents regardless. Make them agree — indenting the selected paragraphs is the Notes-style behavior.
- **The custom paste path skips two built-in-paste niceties** (added 2026-08-15, note-editor review): `NoteTextView.insertSanitized` neither calls `scrollRangeToVisible` after moving the caret (paste a long block and the insertion point can end up off-screen) nor sets an undo action name, so the Edit menu reads bare "Undo" instead of "Undo Paste".
- **Spell checking is off in notes** (added 2026-08-15): a code-created `NSTextView` defaults `isContinuousSpellCheckingEnabled` to false. For free-form notes it should be on.
- **Format bar segments lack tooltips** (added 2026-08-15): the SF Symbols carry accessibility descriptions, but sighted users get no hover hint of what a segment does or its shortcut; `setToolTip(_:forSegment:)` is cheap. (Indent shortcuts ⌘[/⌘] were considered and rejected — DESIGN §7A.4 already assigns them to Previous/Next Week.)
- **Strikethrough as a fourth trait** (added 2026-08-15, product decision needed): crossing things off is natural in a planner, and it follows the underline pattern almost mechanically — sanitizer, toggle, format bar, menu.
- **A materialised list newline can outlive its list** (added 2026-08-15, list-visibility fix): starting a list on an empty line inserts a newline to carry the style (TextKit renders markers from storage only). Toggle the list off and leave, and the note persists as a lone `"\n"` — visually empty but non-nil, so the day gets a note dot. Consider trimming a whitespace-only note to nil in `persistBoundNote` or `ModelController`.
- **Note undo history is discarded on every selection change** (added 2026-08-15): `noteUndoManager = UndoManager()` in `plannerSelectionDidChange` means clicking away and back destroys undo for the previous (saved) edit. Defensible — undo grouped per note visit — but the line to revisit if durable per-note undo is ever wanted.
- **Overflow badge can undercount** (`WeekCalendarView.swift:931-937` vs `:844`): rows that `visibleRows` claimed visible but `layout()` then hides aren't counted in "+K".
- **Redundant `hitTest` overrides** (`WeekCalendarView.swift:420-428`, `:610-618`) reimplement NSView's default verbatim; only `DayCellView`'s override earns its keep. Delete the other two.
- **`shortDeadlineString` hardcodes `Date()`** (`Calendar+Month.swift:118`) unlike its tested siblings that take `now:` — its year-boundary behavior is untestable as written.
- **No fetch index on `uuid`** despite it being the identity-lookup key for every chip-click reveal and inspector rebind. A non-unique `fetchIndex` is CloudKit-safe (only *uniqueness constraints* are forbidden). Optional at v1 scale; do it in the CloudKit PR at the latest.
- **Calendar → split title refresh uses `NSApp.sendAction(to: nil)`** (`CalendarViewController.swift:206-211`): if the window isn't key when a resize-driven week-count change lands, the title silently stales. A closure or delegate call is deterministic — and it's the only responder-chain broadcast in an app that otherwise uses SelectionModel.

---

## 7. Test coverage gaps

The suite is genuinely strong on the recurrence engine, selection semantics, and cell overflow. The gaps cluster where the bugs above were hiding:

**Events/Outlook**
- No all-day *recurring* master test anywhere — the gap concealing bug 1.3. Add the weekly-Saturday-at-UTC-midnight case and `absoluteMonthly` day-31.
- No leap-year case: `absoluteYearly` Feb-29 (clamp to Feb 28 in off years) and `absoluteMonthly` day-29 crossing a leap February.
- Spring-forward anchor: no series anchored at 2:30 AM landing in the skipped hour (`atAnchorTime`'s fallback path is unexercised).
- Count-limited series interacting with EXDATE/exceptions: does a retired slot consume the count? (Currently yes, untested — and count-limited rules had no live-data coverage in the spike either.)
- Decoder never sees a payload with `dayOfMonth`/`monthNumber` present.
- The hung-source/timeout path has zero coverage (and is broken — 1.4).

**Model**
- No rollback tests for the mutation setters: `failNextSave` is exercised only for `createProject` and `delete`; nothing verifies `setTitle`/`setDeadline`/`setCompleted`/`setNote`/`setDayNote` restore the previous value and throw.
- The duplicate-DayNote `(createdAt, uuid)` tie-break — documented behavior — has zero coverage; ditto `setDayNote`'s no-op guards and the `noteRTF` round-trip through `setNote`/`noteText`.

**Controllers/views**
- The note-debounce timer's positive path never fires in tests, and the target-mismatch test goes through a shim that bypasses the shipped `noteDebounceFired` guard entirely.
- No test for `windowDidResignKey` flushing, rename-commit-when-save-fails, or Get Info on a *day* selection (the `hasNoteEditableSelection` day branch).
- The surgical did-save fallbacks are untested: multi-parent insert in one save, insert under a collapsed parent, mixed project+unrelated-task delete (bug 2.9b).
- No test mutates a chip in place and asserts appearance (bug 1.2), and none simulates a day change (bug 2.3).
- ~~`NoteTextView`'s key overrides and paste/drop sanitization have zero tests — only the pure helper functions are covered, while the escape hatch (2.4) lives in the view.~~ Largely closed with the 2.4 fix (2026-08-15): drop/paste intake and the Return-with-selection override now have tests; Tab/Backspace overrides remain untested.

---

## 8. Suggested order

1. **The six high bugs (§1)** — each is small and independently shippable. 1.1 and 1.2 first (most user-visible in daily use), then the Outlook cluster 1.3–1.6, each landing with the regression test from §7 that would have caught it.
2. **The spec-drift decisions (§3)** — cheap, and unblocks using DESIGN.md as the spec of record for everything after.
3. **Medium robustness (§2)** — 2.1/2.2 are crashes, 2.3 pairs naturally with 2.2, and 2.4–2.10 are one-sitting fixes.
4. **Performance pass (§4)** — the formatter caching (4.1) is one mechanical PR; 4.4's fetch unification is worth doing before any calendar-fetch behavior change.
5. **Cleanup (§5) and the remaining small fixes (§6)** — good between-features work; 5.3's file split is best done when the calendar is otherwise quiet.
