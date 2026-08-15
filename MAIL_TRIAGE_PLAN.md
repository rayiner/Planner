# Mail Triage: Work Plan

| Field | Value |
| --- | --- |
| **Date** | 2026-08-15 |
| **Status** | Draft — gated on the M0 spike |
| **Parent spec** | `DESIGN.md` (v1 task planner; this plan extends it) |
| **Mockup** | https://claude.ai/code/artifact/7654bca0-cb4d-4298-8014-19a96be2cf1c |

---

## Overview

A second sidebar mode — the way Preview swaps Thumbnails for a Table of Contents. In **Mail mode** the three panes become mailbox list / message list / reading pane. "Recent Mail" is a transient, rolling window (default 3 days) over the Outlook inbox, shown strictly chronologically with no threading. Messages worth keeping are saved into local folders, where they become permanent, thread into conversations, and can be turned into linked tasks.

**This is not an email client.** No compose, reply, forward, edit, mark-read, or flag — no write path to mail exists, structurally, exactly as with calendar events. Mail is read over the same ScriptingBridge/Apple-events bridge the calendar already uses; saving a message copies it into Planner's own Core Data store and never touches Outlook.

## Reuse map

The feature is deliberately shaped like the calendar-events feature, so most hard problems are already solved in this codebase:

| Existing piece | Mail counterpart |
| --- | --- |
| `CalendarEventSource` protocol + `NullEventSource` | `MailSource` protocol + `NullMailSource` |
| `EventCoordinator` (generation gate, keep-stale-on-failure, 30s backstop, `NSCalendarDayChanged`) | `MailCoordinator`, same semantics, window = last N days instead of ±months |
| `EventWindow` | `MailWindow` (rolling `[startOfDay(today − (N−1)), tomorrow)`) |
| `OutlookScripting` vocabulary + `OutlookRecordDecoder` + `OutlookError` / `ExternallyResolvableError` | Extended with the Mail Suite vocabulary; error mapping and the Settings deep link reused as-is |
| `EventStatusView` toolbar status (spinner / warning / nothing) | Reused verbatim for mail refresh status |
| `DayNote` entity pattern (ModelController-only writes, CloudKit-safe rules) | `MailFolder`, `SavedMessage` entities |
| `SelectionModel` changed-fields contract | New fields; existing observers no-op by design |
| Sidebar rename via `TitleTextField` + `editColumn` | Folder rename |
| Delete-confirmation sheet + cascade | Folder delete |

## Key decisions

| Decision | Choice | Rationale |
| --- | --- | --- |
| Mail source | Outlook over ScriptingBridge, read-only | Same bridge, same TCC grant (`com.apple.security.automation.apple-events` + usage string already shipped). No new entitlements. |
| Transient window storage | **Not Core Data.** In-memory `Sendable` values, exactly like events | Same reasoning as §8.6 of DESIGN.md: the store is CloudKit-bound with one writer; mirroring a foreign feed into it creates a reconcile problem. Recent Mail being absent for ~2s after launch is acceptable. |
| Saved mail storage | Core Data: `MailFolder` + `SavedMessage`, written only by `ModelController` | Saving is an explicit user choice of *Planner data*, not a mirror — it must survive Outlook cleanup and (later) sync. All CloudKit rules from DESIGN.md §3 apply: no uniqueness constraints, unordered relationships, optional relationships, UUIDs assigned at the create site, no `awakeFromInsert`/`willSave`. |
| Saving copies, never moves | The Outlook original is untouched (not moved, flagged, or marked read) | Read-only is structural. Also makes save idempotent and crash-safe. |
| Fetch strategy | **Envelope bulk, body lazy.** The window fetch reads envelope keys only; the full body is fetched per message on selection (then cached in-memory for the session) and at save time | The events spike showed `properties` bulk is what makes Apple events viable, but message bodies would bloat the bulk payload by orders of magnitude. Selected-keys bulk cost is an M0 spike question. |
| Threading | Computed at display time from stored headers (`In-Reply-To` / `References`, falling back to normalized subject + participants); **no Thread entity** | Threading is a *view* of a folder, not data. Storing thread membership would need repair on every move/remove. Pure function → trivially testable. |
| Window length | Rolling, default 3 days, adjustable 1–7 via toolbar popup, persisted in `UserDefaults` (`mail.windowDays`) | Small enough to sweep in one sitting; the point is triage, not archive. |
| Mode switching | `PlannerMode` (`.tasks` / `.mail`) on `SelectionModel` with a new `SelectionField.mode`. The sidebar split item persists and swaps its content VC; the **two trailing split items are removed and reinserted per mode**, each pair carrying its own min/max thicknesses, holding priorities, and item style | "One more field on the selection model." Every existing observer already inspects `changedFields`, so adding fields is safe by contract. The trailing items must be per-mode objects because their constraints are mode chrome: the tasks inspector is capped at 380, the mail reader must not be. Tracking separators bind to the split view + divider index, not the items, so they survive the swap. |
| Split geometry across modes | **Divider 0 (sidebar) is shared; divider 1 is per-mode.** Tasks keeps built-in split autosave; Mail's divider-1 position is stored manually in `UserDefaults` and applied with `setPosition(_:ofDividerAt:)` in the same transaction as the content swap, **no animation**. Trailing-pane collapse state is also per-mode. Mail pane minimums (list 300, reader 380) are chosen so both modes' minimum sums equal 920 | The modes want inverted proportions on the right: tasks = wide calendar + narrow inspector; mail = narrow message list (~384) + wide reader. Sharing divider 1 would stretch one-line list rows to ~700pt and cap the reader at the inspector's 380. A frozen sidebar makes the switch read as "content changed", not "layout rearranged" (Preview's effect); a jump cut is invisible while all three panes' content is replaced, whereas animating would slide the toolbar's tracking separator after the cut. One autosave name cannot serve two geometries (the DESIGN.md §2.2 lesson), and matched minimum sums mean switching modes never resizes the window itself. An inherited collapsed state would make Mail open with no reading pane — broken-looking, not collapsed. |
| Mode UI | Sidebar toolbar slot becomes a segmented control: segment click = toggle sidebar (unchanged muscle memory), attached menu = Tasks ⌘1 / Mail ⌘2; same items under the View menu | The system `.toggleSidebar` item cannot grow a menu, so it is replaced by a custom item that forwards to `toggleSidebar(_:)`. The View-menu items are the accessibility/keyboard path and must land in the same PR. |
| Unread indicator | Display Outlook's `isRead` as the blue dot; never write it | Read-only. The dot is a "new since you last looked" cue, not state Planner owns. |
| Attachments | **Metadata only** (name, size). "Open in Outlook" opens the original message while it still exists upstream | Binary attributes are banned by the store rules; file-side-car storage is real work with real edge cases. Revisit only if metadata-only proves painful (open question Q3). |
| Account/folder selection | First Exchange account's Inbox, overridable via `UserDefaults` (`mail.accountName`), matching `events.accountName` | Same convention as the calendar source. Multiple accounts are a non-goal. |
| Task linkage | `Task.sourceMessageUUID: UUID?` (optional attribute, added in the same model version as the mail entities) | One model-version bump for the whole feature. Optional scalar attribute = lightweight migration, CloudKit-safe. The inspector shows a "From: <subject>" chip that reveals the saved message. |

## Data model (model version bump, one migration)

**Entity `MailFolder`** — `uuid: UUID`, `name: String` (default `Untitled Folder`), `sortIndex: Int64`, `createdAt`/`updatedAt: Date`; to-many `messages` → SavedMessage, inverse `folder`, **Cascade**, unordered. Sorted `(sortIndex, uuid)` like everything else.

**Entity `SavedMessage`** — `uuid: UUID`, `messageID: String` (RFC 822 Message-ID; the dedupe key — *indexed, not unique*), `subject: String`, `senderName`/`senderAddress: String`, `recipients: String?`, `receivedAt: Date` (indexed), `body: String?`, `inReplyTo: String?`, `references: String?` (space-joined IDs, parsed by the threading engine), `attachmentNames: String?`, `hasAttachments: Bool`, `outlookID: Int64` (best-effort pointer for Open in Outlook; may go stale), `createdAt`/`updatedAt: Date`; to-one `folder` → MailFolder, **optional in the model** (CloudKit), non-nil enforced by `ModelController` + tests, Nullify.

**Entity `Task`** — gains `sourceMessageUUID: UUID?` (optional, no relationship — a soft link by UUID, same pattern as selection/reveal). Deleting a SavedMessage leaves the task intact with a dangling link the inspector simply hides.

**`ModelController` additions** (the only writer, all throwing after rollback, undo action names set): `createMailFolder()`, `renameMailFolder`, `deleteMailFolder` (cascade + confirm handled by the VC), `saveMessage(_ envelope: MailMessage, body: String?, into: MailFolder) -> SavedMessage` (dedupe: same `messageID` already in that folder returns the existing row), `moveMessage(_:to:)`, `removeMessage(_:)`, `createTask(from: SavedMessage, in parent:)`, plus fetch helpers `mailFolders()`, `messages(in:)`, `savedMessage(uuid:)`, `folderContaining(messageID:)` (drives the "Saved to X" chip in Recent Mail).

## Non-goals

Compose/reply/forward/edit; writing *anything* to Outlook (read flags, moves, deletes); attachment content capture; full-text search; notifications or dock badges; multiple accounts; rule-based auto-filing; syncing saved mail via CloudKit (same deferral as the rest of the store); threading in Recent Mail (explicitly a product decision, not a gap).

---

## PR plan

Incremental, each PR reviewable and mergeable on its own, matching the DESIGN.md conventions. The app builds and behaves identically in Tasks mode after every PR. M1–M3 are pure model/logic PRs with no Outlook and no UI; M7 is the only risky PR, and it is gated by M0.

### PR M0 — Spike: Outlook Mail Suite over ScriptingBridge *(no merge; findings only)*

- **Depends on:** none. **Gates:** M7 (and the feature as a whole).
- Validate against the live Outlook (16.103.x, legacy AppleScript-capable build) exactly as the 2026-08-14 calendar spike did:
  1. Enumerate the Inbox of the first Exchange account; `whose`-filter messages on `timeReceived` for a 3-day range.
  2. Measure bulk envelope reads. Does `arrayByApplyingSelector` support a *selected-keys* record, or does `properties` drag the full `content` along? If bulk-with-bodies is the only option, measure it for a realistic 3-day window (~40 messages) — the fallback is per-message envelope KVC, which the calendar spike showed costs ~0.4s per read and may force a different fetch shape.
  3. Confirm available keys: Message-ID (or `headers` to parse it from), `In-Reply-To`/`References` via `headers`, sender record shape, `isRead`, `hasAttachment`/attachment names, and a stable `id` for later body fetch.
  4. Fetch one message's `content`/`plainTextContent` by id; measure.
  5. Confirm "reveal in Outlook" (`open` on the message object, or the `ms-outlook:` URL scheme).
- **Deliverable:** findings appended to the project memory + this plan updated (especially the fetch strategy and threading-header rows). Known risk to check first: the "new Outlook" WebView2 builds gutted AppleScript support — confirm the installed build keeps the classic Mail Suite.

### PR M1 — Mail value model, window, and coordinator

- **Files:** `Planner/Model/Mail/MailMessage.swift`, `MailWindow.swift`, `MailSource.swift` (+ `NullMailSource`), `MailCoordinator.swift`; `PlannerTests/MailWindowTests.swift`, `MailCoordinatorTests.swift`, `StubMailSource.swift`
- **Depends on:** none (parallel with M0).
- `MailMessage`: `Sendable` value — id, messageID, subject, sender, recipients, receivedAt, isRead, hasAttachments, attachmentNames, threading headers; body deliberately absent (lazy). `MailWindow.current(days:now:calendar:)` = closed-open `[startOfDay(today − (days−1)), startOfDay(tomorrow))`. `MailSource` mirrors `CalendarEventSource` (`envelopes(in:userInitiated:)`, `body(forMessageID:)`). `MailCoordinator` mirrors `EventCoordinator` line for line: generation gate, keep-stale-on-failure, timeout backstop, `NSCalendarDayChanged` refresh, `.plannerMailDidChange`, plus `windowDays` read from `UserDefaults` and an in-session body cache. Ships wired to `NullMailSource`; app unchanged.

### PR M2 — Core Data: folders, saved messages, task link

- **Files:** `Planner.xcdatamodeld` (new version), `MailFolder+CoreData.swift`, `SavedMessage+CoreData.swift`, `TaskItem+CoreData.swift`, `ModelController.swift`; `PlannerTests/MailStoreTests.swift`
- **Depends on:** none (parallel with M1).
- Entities and `ModelController` methods per the data-model section, including dedupe-by-messageID, cascade delete, move/remove, `createTask(from:in:)`, and undo names (`New Folder`, `Rename Folder`, `Delete Folder`, `Save Message`, `Move Message`, `Remove Message`, `New Task`). Lightweight migration verified by a test that opens a copy of a v1-shaped store. All CloudKit rules from DESIGN.md §3 hold.

### PR M3 — Threading engine

- **Files:** `Planner/Support/MailThreading.swift`; `PlannerTests/MailThreadingTests.swift`
- **Depends on:** M2 (operates on snapshots of SavedMessage fields; can also land against plain structs).
- Pure, synchronous: group by reference-chain union-find, fall back to normalized subject (strip `Re:`/`Fwd:`/`AW:` prefixes, case/whitespace-fold) + overlapping participants; threads ordered by newest message, messages within a thread newest-first (matching the mock). Fixture corpus covers: broken References chains, subject-only joins, same subject different conversations (the fallback must require a participant overlap), single-message threads.

### PR M4 — Mode switch shell

- **Files:** `SelectionModel.swift`, `MainSplitViewController.swift`, `MainMenu.xib`, placeholder `MailboxListViewController` / `MailListViewController` / `MailReaderViewController`
- **Depends on:** none of M1–M3 (UI shell only).
- `PlannerMode` + `SelectionField.mode` on `SelectionModel` (also `.mailbox` and `.message` fields, values unused yet). The sidebar split item persists and swaps its content VC on `.mode`; the two trailing split items are swapped wholesale for a per-mode pair (see the geometry decision above). **Split autosave and toolbar identifiers bump** (`MainHorizontalSplit.v4`, `MainToolbar.v7`). Toolbar: sidebar slot replaced by the segmented toggle-with-menu (forwards to `toggleSidebar(_:)`); mode-dependent items shown/hidden via the existing `sidebarToolbarItems` mechanism (`addProject`/`addTask`/`calendarTitle`/`weekNavigation`/`today` in Tasks mode; `newMailFolder`/`mailTitle`/`windowRange`/`refreshMail` in Mail mode — the last three land disabled here). View menu gains Tasks ⌘1 / Mail ⌘2. Mode persists in `UserDefaults`; switching back to Tasks restores selection and first responder. Tasks mode must be pixel-identical to today.
- **Divider behavior, spelled out:** divider 0 (sidebar) and the sidebar collapse state are shared across modes and do not move on switch. Divider 1 is per-mode: Tasks keeps the built-in autosave; entering Mail applies the stored `mail.divider1` position (default: message list at 380) via `setPosition(_:ofDividerAt: 1)` in the same layout pass as the item swap, unanimated; leaving Mail records it. Trailing-pane collapse state is per-mode (the mail reader starts visible even if the tasks inspector was collapsed; `toggleInspector` stays tasks-only in this PR). Mail minimums are list 300 / reader 380 so both modes' minimum sums equal 920 and a mode switch can never force the window to grow. Launching directly into Mail mode restores the tasks autosave first, then applies the mail position, so the first switch back to Tasks lands exactly where it was. Acceptance check: switch modes at minimum window size and at a dragged divider 1 in both modes — the window frame never changes, the sidebar edge never moves, and each mode reopens with its own divider-1 position after relaunch.

### PR M5 — Mailbox sidebar and folder CRUD

- **Files:** `MailboxListViewController.swift`, `MainSplitViewController.swift` (actions + validation), `MainMenu.xib`
- **Depends on:** M2, M4.
- Source-list of Recent Mail + folders (fetched, `(sortIndex, uuid)`, did-save observer, message counts), New Folder (toolbar, File menu in Mail mode, empty-area context menu) with immediate inline rename reusing the `TitleTextField`/`editColumn` machinery from §5, rename on Return/delayed click, delete with the standard confirm sheet + cascade. Selection writes `SelectionModel.selectMailbox`. Recent Mail count stays 0 until M6.

### PR M6 — Recent Mail list and reading pane

- **Files:** `MailListViewController.swift`, `MailReaderViewController.swift`, `Planner/Support/MailLabels.swift` (all user-visible strings, testable like `EventLabels`)
- **Depends on:** M1, M4, M5. Ships against `NullMailSource` / stub in tests.
- Flat chronological `NSOutlineView`: sticky date-group headers (Today/Yesterday/weekday), rows with sender/time/subject/snippet, unread dot from `isRead`, relative times, tabular numerals. Selection writes `.message`; reader shows envelope immediately and fetches the body lazily through the coordinator (spinner in the body area, keep-stale on failure). Expiry banner computes "leaves the window <date>" from `receivedAt + windowDays`. Empty states: "No mail in the last N days." and, with `NullMailSource`, "Planner shows recent Outlook mail here." Action bar buttons render but Save/New Task stay disabled until M8/M9.

### PR M7 — OutlookMailSource (ScriptingBridge)

- **Files:** `Planner/Support/Outlook/OutlookScripting.swift` (Mail Suite vocabulary), `OutlookMailSource.swift`, `OutlookError.swift` (message-shaped failures)
- **Depends on:** M0 (go decision + fetch shape), M1. **Highest-risk PR.**
- Same discipline as `OutlookEventSource`: serial queue, dynamic dispatch by selector, `whose` range filter on `timeReceived`, bulk envelope decode via `OutlookRecordDecoder`, per-id body fetch, TCC preflight and never-launch guard shared with events, errors mapped through `ExternallyResolvableError` so the consent-refusal Settings link works unchanged. **No entitlement or Info.plist changes** — the existing apple-events grant covers Outlook as a whole; verify the existing usage string still reads honestly and amend it if it says "calendar" only (that string edit is this PR's entire plist diff). Wire into `AppDelegate` injection behind the same pattern as events.

### PR M8 — Saving: folders get mail

- **Files:** `MailListViewController.swift`, `MailReaderViewController.swift`, `MailboxListViewController.swift`, `MainSplitViewController.swift`
- **Depends on:** M2, M3, M6 (works fully against the stub source; M7 not required).
- Save to Folder: reader action-bar menu (folders + "New Folder…"), hover button on list rows, row context menu. Save fetches the body first, then calls `ModelController.saveMessage`; failure surfaces the standard alert and saves nothing. Recent rows already saved (via `folderContaining(messageID:)`) dim and show the "Saved to X" chip. Folder selection switches the list to threaded mode: thread rows (subject, participants, count badge, latest date) expanding in place, powered by the M3 engine; reader gains "Message k of n in this conversation", Move to Folder, and Remove (with confirm when it's the message's only copy). Drag-a-row-onto-a-folder is optional polish — this PR lands without it (the app has no drag-and-drop precedent yet).

### PR M9 — New Task from Message

- **Files:** `MailReaderViewController.swift`, `InspectorViewController.swift`, `OutlineViewController.swift`, `ModelController.swift` (if not fully landed in M2)
- **Depends on:** M2, M8.
- "New Task from Message" saves the message if unsaved (prompting for a folder), then creates a task titled from the subject with `sourceMessageUUID` set, under the outline's selected project/task, else the first project, else it creates one — same fallback chain as ⌘T. Switches to Tasks mode with the new task selected and renaming, matching create-task behavior. Inspector shows a "From: <subject>" chip on linked tasks; clicking switches to Mail mode and reveals the saved message. Dangling links (message removed) hide the chip.

### PR M10 — Refresh, window control, and polish

- **Files:** `MainSplitViewController.swift`, `MailCoordinator.swift`, `MailListViewController.swift`
- **Depends on:** M6, M7.
- `EventStatusView` reused next to the mail title: spinner while fetching, warning-with-tooltip on failure (retry, or Settings deep link on consent refusal), nothing otherwise. View → Refresh (⌘R) routes per mode and disables while in flight. Window-length popup (Last 1–7 Days) writes `mail.windowDays` and refreshes. Day-rollover already handled by the coordinator. VoiceOver labels for rows, threads, and the expiry banner via `MailLabels`; full keyboard path (mode ⌘1/⌘2, list arrows, Save ⌘S-equivalent as a menu item). Final QA pass against the mockup.

**Suggested order:** M0 first (it can kill or reshape the feature); M1+M2 in parallel; then M3/M4; M5→M6; M7 whenever after M0/M1; M8→M9; M10 last. Everything except M7 and M10 is buildable and testable with no Outlook on the machine.

## Risks

| Risk | Mitigation |
| --- | --- |
| "New Outlook" builds removed most AppleScript Mail-Suite support | M0 checks the installed build first; if the Mail Suite is gone, the feature is blocked and the plan stops at M0 (documented, not worked around). |
| Bulk `properties` on messages drags full bodies (huge Apple-event payloads) | Envelope-lazy design; M0 measures selected-keys bulk vs. per-message KVC and the fetch shape in M1/M7 follows the numbers. |
| Threading headers unavailable or expensive via `headers` | The engine's subject+participants fallback is designed in from the start; headers only improve precision. |
| A 7-day window on a heavy inbox (hundreds of messages) | Window capped at 7 days; list virtualized by AppKit; count shown in the title so the user sees what they asked for. |
| Mode switch destabilizes existing observers | The `changedFields` contract already requires observers to no-op on unfamiliar fields; M4 adds a regression test that a mode flip posts only `.mode`. |
| Store migration | One model version for the whole feature (M2), additive-only, migration test included. |

## Open questions

1. **Q1 — Save prompt vs. default folder:** should saving from the hover button with no folder chosen drop into a "last used" folder (fast) or always show the folder menu (deliberate)? Mock shows the menu; start there.
2. **Q2 — Where New Task's task lands** when nothing is selected in the outline (M9 currently: first project, else create). Cheap to change later.
3. **Q3 — Attachment contents:** metadata-only until real use proves painful; if it does, side-car files under Application Support keyed by SavedMessage UUID, never Core Data binaries.
4. **Q4 — Should Recent Mail hide already-saved messages** instead of dimming them? Mock dims; dimming preserves the timeline sweep.
