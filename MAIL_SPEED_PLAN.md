# Recent Mail: Making the Outlook Interface Faster (no OAuth)

Measured 2026-09-15 against the live mailbox — Outlook 16.103.2,
`rhashem@mololamken.com`, Inbox of **34,976 messages / 16,255 unread**, and a
3-day window that currently holds **142 messages**. Every number below is a
best-of-three from an interleaved A/B run, so the comparisons hold even though
the absolute values drift (see "Variance").

---

## 1. What the measurements say

### Cost model

```
one script ≈ 150 ms  +  11 ms × (messages read) × (properties read)
```

That is the whole story. There is no cheaper shape hiding in the Mail Suite.

| Operation | Cost |
| --- | --- |
| `osascript` process + connect to Outlook | 40 ms + 110 ms |
| `id of message 1` + `unread count of inbox` | **200 ms** |
| Head probe — `id` + `is read` of `1 thru 16` | **515 ms** |
| Index scan as shipped — `id` + `is read` of `1 thru 142` | **3,390 ms** |
| Full sweep as shipped — 5 properties over `1 thru 142` | **7,700 ms** |
| `windowCount` binary search (15 probes) | 540 ms |
| One body — `plain text content of message id N` | **180 ms** |
| One `headers of message id N` | 150 ms |
| `properties of` a single message | 237 ms, 40 keys, ~2.4 MB |

### Four findings that change the design

**All five envelope properties cost the same.** `id`, `subject`, `time
received`, `is read` and `sender` each land within 7% of one another at
N=142. The AE-record `sender` is not the outlier it looked like. So there is
no property to drop for a cheap win — only *fewer messages* and *fewer
properties* matter.

**Chunking is essentially free.** Walking 142 messages as four scripts of 40
costs 4% more than one script of 142 (8,546 ms vs 8,221 ms in the same run).
The slice loop in `readFullEnvelopes` is not a cost worth removing, and it is
what makes streaming results (§2.4) nearly free to add.

**Outlook caches nothing between reads.** The same range read four times in a
row costs the same every time (2,584 / 2,455 / 2,476 / 2,355 ms). There is no
warm-up to exploit; a read avoided is the only read made cheap.

**Bodies cost 180 ms, not the 10 ms the M0 spike recorded.** That is an 18×
correction, and it matters: the summarizer pulls a body for every message in
the window, so summaries alone are ~25 s of Apple events per full window on
top of the model time.

### Variance

The same query measured 1,742 ms and 8,221 ms an hour apart. Outlook's Apple
event responsiveness swings up to 5× depending on whether it is syncing. Two
consequences:

- Never tune against a single measurement; always interleave the A/B.
- **Do not tighten `MailCoordinator.timeoutSeconds` (60 s).** It is correctly
  sized for the bad end of that range, not the good end.

### Where the time actually goes today

There is no periodic refresh anywhere in the app. `mail.refresh()` runs on
first view load, on the Refresh command, on the error-retry button, and on day
rollover — nothing else. So the feed sits stale for hours and the user pays a
cold 3.4 s (incremental) or 7.7 s (full) sweep at exactly the moment they went
looking for mail. Fixing *when* we fetch matters as much as fixing *how fast*.

---

## 2. Tier 1 — read less (no new permissions, no new dependencies)

Ordered by payoff over effort. Items 2.1–2.3 compound; do them together.

### 2.1 A 200 ms "has anything changed?" probe before any scan

One script returning three numbers: `id of message 1 of inb`, `count of
messages of inb`, `unread count of inb`. Store them with the envelope sidecar.
If all three match the last sweep, republish from cache and stop.

- **3,390 ms → 200 ms** on the common automatic refresh, a 17× cut.
- Not a proof of "unchanged" — an arrival plus a deletion in the same interval
  can cancel out in all three. The cost of being wrong is a list that stays
  stale until the next refresh, which is strictly better than today's
  behaviour of not refreshing at all.
- **Apply to automatic refreshes only.** A user-initiated refresh means "I
  don't believe you", and must always do the real work.

### 2.2 Exponential head probe instead of the full index scan

New mail is a leading prefix — `MailEnvelopeSweep.plan` already relies on it.
So do not scan 142 ids to find 3 new ones. Read `id of messages 1 thru 16`;
if any id at the tail of that probe is already known, the new prefix is fully
contained and we are done. Otherwise widen to 32, 64, then the full count.

- **3,390 ms → 515 ms** in the common case (0–3 new messages), a 6.6× cut.
- Deletions shift indices, so diff the probe against the *known prefix* rather
  than testing membership alone; a mismatch that is not a clean prefix widens
  the probe, and a full mismatch falls back to the current full read.
- `MailEnvelopeSweep.plan` keeps its job unchanged. Only the ids it is handed
  get cheaper to obtain.

### 2.3 Refresh read flags only when the unread count moved

The index scan reads two properties over the window: `id` (for the prefix) and
`is read` (for the unread dots). Split them. Read `is read` across the window
only when `unread count of inb` differs from the last sweep's — the probe in
2.1 already has that number, so it costs nothing extra.

- Halves the remaining scan whenever nothing was read or marked unread.
- Folder-wide, so on a 16,255-unread inbox it will fire often. Still never
  worse than today, and free to check.

### 2.4 Stream each slice to the list instead of collecting all of them

`readFullEnvelopes` walks slices of 40 and returns only when all of them have
landed. Publish each slice as it arrives instead.

- First 40 rows visible at **~2.2 s instead of ~7.7 s**. Slice 1 is the newest
  40, which is exactly what is on screen, so no reordering is needed.
- The 4% chunking overhead already measured is the entire cost.
- Needs a partial-publish path in `MailCoordinator.apply` and a state that
  says "these rows are real, more are coming". The list already draws a
  loading affordance, so this is mostly plumbing.
- This is the largest perceived-speed win available without changing the
  mechanism.

### 2.5 Give the summarizer its own priority tier

`MailAppleEventQueue` has two tiers, `.detail` and `.sweep`, and `.detail`
always wins. The summarizer's body fetches go through
`MailCoordinator.loadDetail`, so they enter at `.detail` — the same tier as a
user clicking a message. Two bad consequences:

- A click can queue behind a background summary's 180 ms body fetch.
- Background bodies preempt sweep slices, stretching a sweep the user is
  watching.

Add a third tier: `.interactive` (a click, a reveal) > `.sweep` > `.background`
(summaries, prefetch). Additionally, pause the summarizer's pump while a sweep
is in flight — it has no deadline, and the sweep does.

### 2.6 Seed the window-count search instead of running it cold

The in-script binary search costs 540 ms and a whole round trip. The previous
sweep's count is almost always within a few of the current one, so verify it
with two point reads — `time received of message k` and of `k+1` — folded into
the 2.1 probe script for **zero extra round trips**. Fall back to the full
binary search only when the guess straddles wrong.

Do *not* replace it with "walk slices until one predates the cutoff": that
over-reads up to 40 messages × 5 properties (~2.2 s) to save 540 ms.

### Projected Tier 1 result

| Case | Today | After |
| --- | --- | --- |
| Automatic refresh, nothing new | 3,390 ms | **200 ms** |
| Automatic refresh, 3 new messages | 3,390 ms | **~900 ms** |
| Cold full sweep, first rows on screen | 7,700 ms | **~2,200 ms** |
| Cold full sweep, complete | 7,700 ms | 8,000 ms |

---

## 3. Tier 2 — fetch before being asked

Tier 1 makes the refresh cheap. Tier 2 makes sure the user is never the one
who triggers it.

### 3.1 Poll with the cheap probe, on a low frequency

Run the 200 ms probe from 2.1 once a minute on a background tier. When it says
something changed, run the head probe and the prefix read. That is 0.2 s of
Apple events per minute — negligible against Outlook's own activity.

- The user's explicit refresh then almost always hits the "nothing changed"
  path, so it returns in 200 ms.
- The list is continuously fresh, which is the actual thing being asked for.
- `preflight` already refuses to send when Outlook is not running and when
  consent is undetermined, so polling can neither launch Outlook nor raise a
  TCC dialog. Verify that holds before shipping.
- Pause the poll when the window is not visible, and back it off while a sweep
  or a user action is in flight.

**This is the best cost-to-benefit item in the plan.** It needs no new
permissions and no new mechanism.

### 3.2 Prefetch bodies for the top visible rows

A click costs 180 ms plus whatever is ahead of it in the queue. Prefetch the
newest ~10 bodies at the new `.background` tier so opening is instant. The
summarizer partly does this already, but in summary order and behind a 1.4 s
model call per message.

### 3.3 Persist the body cache to disk

`detailCache` dies with the process, so every relaunch re-fetches every body
the summarizer wants — 142 × 180 ms ≈ 25 s of Apple events. Bodies are
immutable once received, so a sidecar keyed by message id is safe.

- Use a bounded local JSON sidecar; prune on the same window.
- Bodies are the largest privacy surface in the feature, so cap the file size
  and prune aggressively. Worth an explicit decision rather than a default.

---

## 4. Tier 3 — change the mechanism

Everything above is arithmetic on an 11 ms-per-property-read constant. Only
this tier removes the constant.

### 4.1 Read Outlook's local SQLite profile directly — **SPIKE DONE, ALL GATES PASS**

Run 2026-09-15 against the live mailbox. All three gates cleared, and the
result is better than the tier was written to hope for.

```
~/Library/Group Containers/UBF8T346G9.Office/Outlook/
  Outlook 15 Profiles/Main Profile/Data/Outlook.sqlite      (274 MB, WAL)
  Messages/<folder>/<uuid>.olk15Message                     (one file per message)
```

**Gate 1 — permission: PASS.** Readable from a process with Full Disk Access
while Outlook is running. Opened `mode=ro` with `PRAGMA query_only`, took 2.2 ms,
saw a message that had arrived *after* the snapshot, left no files behind and
did not disturb Outlook. Readers do not block the writer in WAL mode.

> **Do not pass `immutable=1`.** It ignores the WAL and silently serves a stale
> snapshot — it returned 34,976 rows and a newest id of 191273 while the live
> read returned 34,977 and 191274.

**Gate 2 — schema: PASS.** Full survey in `OUTLOOK_SQLITE_FORMAT.md`. The
`Mail` table carries every field the sweep needs, and Microsoft ships an index
in exactly Planner's query shape:

```sql
CREATE INDEX MailIndex_TimeWindow ON Mail
  (Record_FolderID ASC, Message_TimeReceived DESC, ...);
```

| Need | Column |
| --- | --- |
| id | `Record_RecordID` |
| received | `Message_TimeReceived` (Unix epoch) |
| read flag | `Message_ReadFlag` |
| sender name / address | `Message_SenderList` / `Message_SenderAddressList` |
| subject (prefix stripped) | `Message_NormalizedSubject` |
| body + headers | `PathToDataFile` → the `.olk15Message` file |
| threading | `Message_MessageID`, `Conversation_ConversationID`, `Threads_ThreadID` |
| attachments | `Message_HasAttachment` |
| snippet | `Message_Preview` |
| Inbox folder | `Folders.Record_RecordID` where `Folder_SpecialFolderType = 1` |

**Gate 3 — identity: PASS.** `Mail.Record_RecordID` *is* the AppleScript message
id, and `Folders.Record_RecordID` is the AppleScript folder id — Outlook's own
error messages say `mail folder id 110`. So `detail` and `reveal` keep working
unchanged and this is a drop-in replacement for the envelope sweep alone.

#### Measured

| | AppleScript | SQLite + files |
| --- | --- | --- |
| Envelope sweep, 143-message window | 3,456 ms (7,700 ms at the bad end) | **5.6 ms** |
| Same, plus every body and header | ~48 s | **17 ms** |
| Inbox totals (34,976 / 16,255 unread) | 153 / 186 ms | 2 ms |

Counts, id order and read flags matched exactly. The one-time snapshot of all
144 message files is 12.3 MB read and parsed in 17 ms, which replaces the
180 ms body fetch *and* the 150 ms headers fetch per message.

#### Verified equivalence over the full window

Compared field by field against the AppleScript sweep, 143 messages:

| Field | Result |
| --- | --- |
| id and ordering | **143/143** |
| read flag | **143/143** |
| subject | **143/143** (after the two fixes below) |
| sender name + address | **20/20** sampled |
| time received | ordering identical; spot checks match to the second |

**Subject needs no header parsing at all.** The `.olk15Message` file is a
property store, not an opaque blob — its format is documented in
`OLK15MESSAGE_FORMAT.md`. Property `0x0100001f` is the display subject, already
decoded Unicode, present on **144/144** messages including meeting invites, and
identical to AppleScript's `subject` on all of them.

That supersedes the two workarounds this section originally proposed. There is
no `Subject:` header to unfold, no RFC 2047 encoded-word decoder to write, and
no `Message_MessageListData` blob walk for meeting invites. Parsing all 144
files takes 34 ms.

The same file also yields, all verified:

| Need | Property |
| --- | --- |
| subject | `0x0100001f` |
| HTML body | `0x1e00001f` — exactly AppleScript `content`, modulo CRLF→CR |
| body without the quoted chain | `0x6200001f` |
| RFC822 headers | `0x0400001e` — headers only |
| `Message-ID` / `In-Reply-To` / `References` | `0x0200001e` / `0x2200001e` / `0x2400001e` |
| sender name + address | sub-record `0x0300000d`, 144/144 against the database |
| time received | `0x0200004d` |

**One gap to design around: there is no full plain-text body.** `0x2700001f` is
the 255-character preview, equal to the `Message_Preview` column, not
`plain text content`. Plain text has to be derived from the HTML. Planner
already does this — `MailSummaryPrompt.plainBody` falls back to
`stripHTML(html)` when the body is empty, and
`MailBodyFormatting.attributedString(html:plain:)` prefers the HTML — so a
detail built from the file can leave `body` empty and set `html`.

`0x6200001f` is a bonus worth taking: it is the message without its quoted
reply chain, which is exactly what `MailSummaryPrompt.withoutQuotedReplies`
currently reconstructs by hand for the summarizer.

#### What this changes

The envelope sweep stops being the bottleneck by three orders of magnitude, and
bodies and headers come free with it. That removes the reason for most of
Tier 1: streaming slices (2.4), the head probe (2.2) and the read-flag gating
(2.3) are all optimisations of a cost that no longer exists.

**Recommended sequencing change.** Do 2.5 (the priority tier) and 2.1 (the cheap
probe) anyway — they are small and they make the AppleScript fallback path
behave. Then build this, and drop 2.2, 2.3 and 2.4 unless the fallback path
turns out to matter more than expected.

#### Constraints for the implementation

- **Full Disk Access is a real ask.** Planner is unsandboxed so the grant
  reaches it, but it needs an onboarding affordance and a working app without
  it. Keep the AppleScript source as the fallback whenever the database cannot
  be opened.
- **Read-only, always.** `mode=ro` plus `PRAGMA query_only=1`. Never write,
  never checkpoint, never `VACUUM`. Treat a locked or busy database as a miss
  and fall back rather than retrying into Outlook's write path.
- **The schema is undocumented and can change in any Outlook update.** Validate
  on open: `PRAGMA user_version` (2490368 = schema 38 today, mirrored in the
  `.schema_version` file), the `Mail` table, and the columns actually read. On
  any mismatch, fall back to AppleScript and log it.
- **Never touch the `Files` table.** It is `CREATE VIRTUAL TABLE … USING
  FilesVTabModule`, a module that only exists inside Outlook, so any other
  SQLite client errors the moment it queries it. Skip virtual tables when
  enumerating.
- **Watch the datetime units.** `Message_TimeReceived` is Unix seconds but
  `Calendar_StartDateUTC` is *minutes since 1601*, and the sidecar files use a
  double counting seconds from 2001. Three encodings, all declared `DATETIME`.
  Convert explicitly at the boundary. See `OUTLOOK_SQLITE_FORMAT.md` §5.
- **`reveal` stays on AppleScript.** It is a command, not a read.
- **`.olk15Message` is parseable but undocumented.** Format in
  `OLK15MESSAGE_FORMAT.md`. Validate the `CRLM` magic and the size invariant on
  every file and fall back to the Apple event path on any failure.
- **Hidden rows exist.** Filter `Message_Hidden = 0`, as the queries above do.

### 4.2 Ruled out: network protocols

Both obvious "avoid OAuth" alternatives are dead ends against Exchange Online,
which is what `mololamken.com` is:

- **EWS with Basic auth.** Microsoft disabled basic authentication for EWS on
  Exchange Online, and EWS itself is being retired for Exchange Online. Worth
  re-confirming against current Microsoft documentation before relying on this
  paragraph, but the direction is settled.
- **IMAP with Basic auth.** Also disabled for Exchange Online tenants.

Neither is available without OAuth. This is not a gap in the plan; it is why
the plan is about the local interface.

---

## 5. Suggested order

1. **2.1 + 2.2 + 2.3 together** — one PR. They share the probe script and the
   sidecar fields, and separating them would mean writing the probe twice.
   This is the 17× cut on the common path.
2. **2.5** — the priority tier. Small, self-contained, and it stops background
   work from making foreground work look slow. Do it before 3.1, which adds
   more background work.
3. **2.4** — streaming slices. The big perceived-speed win, and the one most
   visible to the user.
4. **3.1** — the background poll. Depends on 2.1 for the probe and on 2.5 for
   the priority tier.
5. **3.2 + 3.3** — body prefetch and the on-disk body cache. Do 3.3's privacy
   decision first.
6. **2.6** — the seeded window count. Smallest win here; fold it into whichever
   PR is already touching the probe script.
7. **4.1 is no longer a spike — it is the plan.** All three gates passed on
   2026-09-15 and the sweep drops from ~3.5 s to ~6 ms. Build it after 2.5 and
   2.1, and drop 2.2, 2.3 and 2.4 unless the AppleScript fallback path proves
   to matter. The open work is the Full Disk Access onboarding, the schema
   validation on open, and a `.olk15Message` parser in Swift (about 20 lines —
   see `OLK15MESSAGE_FORMAT.md` §5).

---

## 6. Re-running these measurements

The benchmark harness is throwaway Python driving `osascript`. The shape that
matters:

```python
# interleave the cases; take best-of-three; never compare across runs
for _ in range(3):
    for label, script in cases.items():
        times[label].append(time_one(script))
```

Two traps found while measuring today:

- `set msgs to messages 1 thru N of inb` then `id of msgs` **does not work** —
  it evaluates to a list of object references and the property read fails with
  `Can't get id of {incoming message ...}`. It also looked 4× faster than the
  baseline, because failing is quick. Always assert on the returned data, not
  just the elapsed time.
- AppleScript's `current date` has one-second resolution, so in-script timing
  is useless at these scales. Time from outside.
