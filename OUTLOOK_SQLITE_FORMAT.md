# `Outlook.sqlite`: the Outlook for Mac profile database

Surveyed 2026-09-15 against Outlook 16.103.2, schema version 38, a profile with
57,130 mail records. Read live and read-only while Outlook was running.
Everything below was checked against the database itself; claims cross-checked
against Outlook's own AppleScript values say so.

Companion documents: `MAIL_SPEED_PLAN.md` §4.1 for why Planner cares,
`OLK15MESSAGE_FORMAT.md` for the per-message sidecar files this database points
at, and `OLK15MSGSOURCE_FORMAT.md` for the raw-MIME blocks a minority of
messages also carry.

```
~/Library/Group Containers/UBF8T346G9.Office/Outlook/
  Outlook 15 Profiles/Main Profile/Data/
    Outlook.sqlite            274 MB, WAL
    .schema_version           4 bytes
    BlockLocks.sqlite         cross-process block locks
    RecordLocks.sqlite        cross-process record locks
    Messages/ Folders/ Contacts/ Events/ Tasks/ Notes/ …   the content
```

---

## 1. The central idea: the database is an index, not the content

Almost every table has a `PathToDataFile` column. The row holds what Outlook
needs to list, sort, filter and sync; the actual item lives in a sidecar file
next to the database. `Mail` is the clearest case: 46 columns of metadata, and
the subject-with-prefix, headers and body are all in the `.olk15Message` file.

That split is why the database is fast to query and why a reader usually needs
both halves.

Two consequences worth designing around:

- **A path can outlive nothing and a file can outlive its row.** Deleting a
  `Blocks` row fires a trigger that inserts the path into `FilesToPurge`, so
  file removal is asynchronous garbage collection. Tolerate a missing file.
- **File presence is good in practice.** Across the newest 2,000 and oldest
  2,000 mail rows, every `PathToDataFile` existed on disk.

---

## 2. Pragmas and versioning

| pragma | value |
| --- | --- |
| `page_size` | 4096 |
| `encoding` | UTF-8 |
| `journal_mode` | **wal** |
| `user_version` | 2490368 = `0x260000`, i.e. schema **38** |
| `application_id` | 0 |
| `auto_vacuum` | 0 |

The `.schema_version` file holds the same value as four little-endian bytes
(`00 00 26 00`). **Pin compatibility checks to `user_version`**, and refuse to
parse an unexpected value rather than guessing, since nothing here is
documented or contractual.

43 tables, 62 indexes, 3 triggers.

---

## 3. Naming conventions

Once you see these, the schema reads itself.

| prefix | meaning |
| --- | --- |
| `Record_…` | generic to every record: `Record_RecordID`, `Record_ModDate`, `Record_FolderID`, `Record_AccountUID`, `Record_ExchangeOrEasId`, `Record_ExchangeChangeKey` |
| `Message_…`, `Calendar_…`, `Folder_…` | fields specific to that entity |
| `X_OwnedBlocks` | join table from entity `X` to the blocks it owns |
| `X_Categories` | join table from entity `X` to `Categories` |

`Record_RecordID` is the entity's primary key **and** the id Outlook's
AppleScript interface exposes. Verified for both messages and folders: asking
AppleScript about a message by id returns the row whose `Record_RecordID`
matches, and Outlook's own error text names the Inbox as `mail folder id 110`,
matching `Folders.Record_RecordID`.

---

## 4. Tables

### Entities

| table | rows here | notes |
| --- | --- | --- |
| `Mail` | 57,130 | 46 columns, 12 indexes |
| `CalendarEvents` | 1,521 | recurrence via `Calendar_MasterRecordID` / `Calendar_RecurrenceID` / `Calendar_UID`; see §9 |
| `Contacts` | 226 | plus `Contacts_AutoFill` for address completion |
| `Folders` | 89 | the folder tree |
| `Tasks`, `Notes` | 3, 1 | |
| `O365Groups` | 10 | |
| `Categories` | 19 | colour categories |
| `Rules`, `Signatures`, `SavedSpotlightSearch` | | |
| `AccountsExchange`, `AccountsMail`, `AccountsLdap` | 2, 2, 0 | |

### Threading

| table | rows | notes |
| --- | --- | --- |
| `Conversations` | 24,802 | `Conversation_ConversationID`, thread type, server thread id |
| `Threads` | 24,849 | joins to `Conversations`, holds server and local thread GUIDs |

`Mail` references both directly, so conversation grouping needs no header
parsing. Two triggers keep them tidy: deleting a message or changing its
conversation deletes orphaned `Conversations` and `Threads` rows.

### The block store

| table | rows | notes |
| --- | --- | --- |
| `Blocks` | 59,630 | `BlockID` BLOB primary key, `BlockTag`, `PathToDataFile` |
| `Mail_OwnedBlocks` | 58,696 | `Record_RecordID` → `BlockID` |
| `FilesToPurge` | 0 | queue of files to delete, filled by a trigger |

`BlockID` is 20 bytes: a 4-byte prefix then the 16-byte UUID that also names the
file. `BlockTag` is a FourCC:

| tag | ASCII | directory | count |
| --- | --- | --- | --- |
| `0x41747463` | `Attc` | `Message Attachments/` | 55,511 |
| `0x4d537263` | `MSrc` | `Message Sources/` | 3,822 |
| `0x436c4174` | `ClAt` | `Calendar Attachments/` | 223 |
| `0x4578534d` | `ExSM` | `Exchange Sync/` | 64 |
| `0x45784653` | `ExFS` | `Exchange Sync/` | 6 |
| `0x496d6742` | `ImgB` | `Images/` | 2 |
| `0x53674174` | `SgAt` | `Signature Attachments/` | 1 |
| `0x52636e41` | `RcnA` | `Recent Addresses/` | 1 |

Note `MSrc`, the raw MIME source, exists for only 3,822 of 57,130 messages. It
is not a reliable body source; the `.olk15Message` file is. Where it *does*
exist it is the complete original message, attachments included, which the
sidecar never is — see `OLK15MSGSOURCE_FORMAT.md`. Treat it as an opportunistic
upgrade over the sidecar, never as the default path.

Most messages own one block; the distribution tails off from there (17,496 own
one, 6,494 own two, 2,986 own three).

### Not readable outside Outlook

`Files` is `CREATE VIRTUAL TABLE Files USING FilesVTabModule`. That module ships
inside Outlook, so any other SQLite client fails with `no such module:
FilesVTabModule` **the moment it touches that table**. Opening the database and
querying everything else is fine. Enumerate `sqlite_master` and skip any table
whose SQL contains `VIRTUAL`.

---

## 5. Two datetime encodings, and they differ

Every timestamp column is declared `DATETIME`. SQLite does not enforce that, and
all of them actually store integers — in **two different units with two
different epochs**. This is the single most dangerous thing in the schema.

| column | encoding |
| --- | --- |
| `Mail.Message_TimeReceived`, `Message_TimeSent` | **seconds since 1970-01-01 UTC** (Unix) |
| `Record_ModDate` (all tables) | seconds since 1970-01-01 UTC |
| `CalendarEvents.Calendar_StartDateUTC`, `Calendar_EndDateUTC` | **minutes since 1601-01-01 UTC** (the Windows FILETIME epoch, in minutes) |
| `CalendarEvents.Calendar_DismissTime` | seconds since 1970-01-01 UTC (Unix) — **not** the calendar encoding, despite the `Calendar_` prefix |

Both verified against Outlook's own values: 25 of 25 messages matched Unix
seconds, and 25 of 25 calendar events matched minutes-since-1601 to the second.
The calendar epoch resolves to exactly `1601-01-01 00:00:00 UTC` on every event
tested.

A calendar value read as Unix seconds lands in the 1970s, which is obvious. The
reverse mistake is not, so convert explicitly at the boundary.

**The prefix is not the rule.** `Calendar_DismissTime` sits in the same table as
the two minutes-since-1601 columns and stores Unix seconds. Decoded as the
columns beside it, its values land in the year 4700. It also carries two
sentinels rather than NULL — `79870665540` for never (1,467 of 1,526 rows here)
and `978307200`, Unix time for 2001-01-01, for unset (34 rows) — so only the
remaining 25 are real dismissals. Confirmed from both ends: the sidecar stores
the same value as a seconds-from-2001 double, and converting that to Unix
reproduces the column exactly on all 1,492 rows that carry it (§9.5).

Note also that the `.olk15Message` sidecar files use a **third** encoding: an
IEEE double counting seconds from 2001. See `OLK15MESSAGE_FORMAT.md` §2.

---

## 6. Folders

`Folders` is a parent-pointer tree: `Folder_ParentID` → `Record_RecordID`, with
a per-account pseudo-root and `-2` above that. Find a well-known folder by
`Folder_SpecialFolderType` rather than by name, which is localised.

| type | folder |
| --- | --- |
| 0 | ordinary user folder |
| 1 | Inbox |
| 2 | Outbox |
| 3 | Contacts |
| 4 | Calendar |
| 5 | Notes |
| 6 | Tasks |
| 8 | Sent Items |
| 9 | Deleted Items |
| 10 | Drafts |
| 12 | Junk Email |
| 15 | Archive |
| 99, 101, 102, 103, 106, 108, 111 | account root and public-folder roots |

Scope by `Record_AccountUID`: each account has its own Inbox row.

Placeholder rows exist (`Placeholder_Inbox_Placeholder`, account uid 0) and
should be filtered out.

---

## 6.1 Accounts, and why `Record_AccountUID` does not join

Added 2026-09-16. `Record_AccountUID` on `Mail` and `Folders` is **not a row id**
and does not join to any `Record_RecordID`. The values here are `60129542145`
and `60129542146` — `0xE00000001` and `0xE00000002` — while `AccountsExchange`
and `AccountsMail` both number their rows `1` and `2`. The high `0xE` nibble is
a type tag on an otherwise small index, so a naive join silently returns
nothing and every account renders as a bare number.

Two ways across, and a reader wants both:

- `AccountsExchange.Account_MailAccountUID` holds the full uid directly. This is
  the reliable path for Exchange accounts.
- Otherwise mask to the low 32 bits: `Record_AccountUID & 0xFFFFFFFF` is the
  `AccountsMail.Record_RecordID`.

`AccountsExchange` and `AccountsMail` carry `Account_Name` and
`Account_EmailAddress`; neither has a `Record_AccountUID` column at all, which
is the tell that the join was never meant to go that way.

---

## 6.2 Categories, and why they are per account

Added 2026-09-17. `Categories` carries `Record_AccountUID` and Outlook indexes
on it (`CategoriesIndex_AccountUIDAndIsLocalCategory`), so the catalogue is
**per account**. The survey profile has 20 in three groups: 8 under uid `0`,
which is Outlook's built-in set and belongs to no account, and 6 under each of
the two mail accounts.

**A name is not an identity.** Names are unique only within an account — two
accounts may each define a "Hide" — so a reader keyed on the name alone will
silently merge them the day that happens. Key on `Record_RecordID` within a
profile, and on `Cateogry_ExchangeGuid` across profiles. That column name is
Microsoft's typo, not a transcription error here; it is spelled `Cateogry` in
the schema.

**The account scopes what is offered, not what may be assigned.** Of the 63
rows in `Mail_Categories`, 62 are a category applied within its own account and
one is not: a message belonging to account `…145` carries a category belonging
to account `…146`. Store the assignment as a pointer to the category row, never
as "the category of this name in this item's account".

The join tables — `Mail_Categories`, `CalendarEvents_Categories`,
`Contacts_Categories`, `Tasks_Categories`, `Notes_Categories` — all have the
same three columns, and a row can exist with a NULL `Category_RecordID`; every
`CalendarEvents_Categories` row in this profile is one. Presence of the row
means nothing, only a non-NULL category id does.

### The colour encoding

`Category_BackgroundColor` is a 6-byte blob: three **little-endian 16-bit**
channels, so the meaningful byte of each pair is the **second**.

| category | stored | correct | wrong byte |
| --- | --- | --- | --- |
| Personal (built-in) | `424299990000` | `#429900` | `#429900` |
| Yellow category | `00F800F20064` | `#F8F264` | `#000000` |
| Orange category | `00F1009D005A` | `#F19D5A` | `#000000` |
| Blue category | `0074009900E1` | `#7499E1` | `#000000` |

The trap is that the built-in categories store each byte twice, so a sample
drawn from them alone decodes correctly under either reading and the bug only
appears once an Exchange category is in the sample — where it turns every
colour black. The six colour-named categories are the check: they must come out
orange, blue, green, purple, red and yellow.

---

## 7. Indexes

62 of them, and they are well matched to the obvious queries. `Mail` alone has
12, including one that is exactly the shape a "recent mail" pane wants:

```sql
CREATE INDEX MailIndex_TimeWindow ON Mail
  (Record_FolderID ASC, Message_TimeReceived DESC,
   Message_TimeSent DESC, Message_InferenceClassification ASC);
CREATE INDEX MailIndexUnreadCount ON Mail (Record_FolderID, Message_ReadFlag);
CREATE INDEX MailIndexConversationID ON Mail (Conversation_ConversationID);
CREATE INDEX MailIndexThreadID       ON Mail (Threads_ThreadID);
```

**There is no full-text index.** Nothing here is FTS3/4/5. Outlook's own search
is Spotlight over the sidecar files, not a table in this database. Any content
search against the database alone means reading the sidecar files.

---

## 8. Locking, and reading safely

`BlockLocks.sqlite` and `RecordLocks.sqlite` are separate one-table databases
mapping a block id or record UUID to an owning `ProcessID`. They are Outlook's
own cross-process advisory locks; both were empty during this survey, so Outlook
takes them transiently. **A pure reader does not participate in them.**

For reading the live database while Outlook runs:

- Open with `mode=ro` and set `PRAGMA query_only=1`. Measured 2.2 ms for a
  count plus a newest-row lookup. Outlook was unaffected, and no files were
  left behind.
- **Never pass `immutable=1`.** It bypasses the WAL and silently serves a stale
  snapshot: it reported 34,976 rows and newest id 191273 while the correct live
  read reported 34,977 and 191274.
- Never write, never checkpoint, never `VACUUM`. Treat a busy or locked
  database as a cache miss and fall back rather than retrying into Outlook's
  write path.
- Percent-decode `Blocks.PathToDataFile` before using it — it is URL-encoded
  (`Message%20Attachments/…`) and 59,628 of 59,630 rows contain an escape. The
  entity tables' `PathToDataFile` values happen to contain no escapes because
  their directories have no spaces, so decode everywhere rather than relying on
  that.

---

## 9. Calendar items

Surveyed 2026-09-16 against the same profile: 1,521 events at the §4 count,
1,526 by the time of this pass. The §1 split applies in full — the row is the
index, the `.olk15Event` sidecar is the content — and it bites harder here than
it does for mail, because **none** of the fields a person would use to recognise
an appointment is in the database.

### 9.1 The row

`CalendarEvents` has 21 columns:

| group | columns |
| --- | --- |
| record | `Record_RecordID` (PK), `PathToDataFile`, `Record_ModDate`, `Record_FolderID`, `Record_AccountUID`, `Record_UUID`, `Record_ExchangeOrEasId`, `Record_ExchangeChangeKey`, `Record_Recover` |
| time | `Calendar_StartDateUTC`, `Calendar_EndDateUTC` |
| recurrence | `Calendar_IsRecurring`, `Calendar_UID`, `Calendar_MasterRecordID`, `Calendar_RecurrenceID` |
| meeting | `Calendar_AttendeeCount`, `Calendar_AllowNewTimeProposal` |
| reminder | `Calendar_HasReminder`, `Calendar_DismissTime` |
| sync | `Calendar_SyncBlocked`, `Calendar_ItemMigrationStatus` |

What is **not** there, and is therefore a sidecar read every time: subject,
location, body, organiser, the attendee list (only a count is stored),
the recurrence rule, the originating time zone (§9.3), the all-day flag (§9.3),
free/busy status, sensitivity, and anyone's response. Of those, only the
recurrence rule is missing from the sidecar too. A calendar list view can be drawn
from the database alone; a calendar *item* cannot.

Two smaller shapes worth knowing:

- `Record_UUID` is declared `TEXT` but reads back as a 16-byte BLOB.
- Events are not confined to the Calendar folder. Here 1,334 sit in a
  `Folder_SpecialFolderType` 4 folder and 192 in ordinary type-0 folders, so
  scope by the `CalendarEvents` table, not by folder type.

### 9.2 Recurrence

The database stores expanded occurrences, never a rule.

- `Calendar_UID` is the iCalendar UID and is shared by a whole series:
  1,443 distinct UIDs across 1,526 rows.
- `Calendar_IsRecurring` is set on 44 rows.
- `Calendar_MasterRecordID` (→ the series master's `Record_RecordID`) and
  `Calendar_RecurrenceID` are non-zero on the same 35 rows — the modified
  occurrences. Both are `0`, not NULL, when absent.

`CalendarEventsIndex_UIDandRecurrence` and
`CalendarEventsIndex_MasterRecordIDAndRecurrenceID` make both directions of the
series lookup an index seek. There are seven indexes in all, including
`Calendar_StartDateUTC DESC`, which is the agenda query.

### 9.3 Times

Start and end are minutes since 1601 (§5) and `Calendar_DismissTime` is not
(§5 again — it is the one trap in this table).

- No row has a NULL or zero start, and no row ends before it starts, so the
  range is safe to use without guards.
- 438 of 1,526 start on an exact UTC minute-1440 boundary. That is the closest
  thing to an all-day signal the row offers, and it is not good enough: 431 of
  those are all-day events and the other 7 are ordinary 60-minute meetings that
  happen to start at midnight UTC. Nothing in the row separates them. The real
  flag is sidecar property `0x0700000b` (§9.5).
- All-day events are stored as **midnight UTC to midnight UTC**, not local
  midnight, and their duration is always a whole number of days — 1,440 minutes
  for 414 of the 431, up to 17,280 (12 days) for the longest. Outlook renders
  them as dates, so converting one to local time and formatting it will move it
  to the previous day at any negative UTC offset.
- The sidecar carries a **second start/end pair in local wall-clock time**
  (`0x17000003` / `0x18000003`, same minutes-since-1601 encoding), so
  `start_utc - start_local` recovers the event's UTC offset even though the row
  cannot. The offsets present here are -480, -420, -360, -300, -240, 0, +60,
  +180, +480 and +540 minutes, and they track daylight saving: March through
  October is mostly -240, November through February mostly -300. It is the
  offset that is recoverable, not the zone's name.
- All-day events have the two pairs equal — delta 0 on all 431 — which is the
  same statement as "an all-day event is a date, not an instant".
- One event starts in 1904. Outliers are data, not a decoding failure.

### 9.4 Attachments and categories

`CalendarEvents_OwnedBlocks` works exactly like `Mail_OwnedBlocks` but carries
only `ClAt` blocks (§4), in `Calendar Attachments/`: 222 of 1,526 events own at
least one, 223 blocks in total, all named `.olk15CalAttachment`.

Those block files are the `Attc` layout, not the `CRLM` one: a fixed 0x28-byte
header (magic `ClAt`, which stored little-endian reads as `tAlC`) followed by
the payload. On all 223 the payload is a self-contained MIME part beginning
`content-type:` — byte for byte what a message attachment block holds, so the
same extractor serves both.

**They use bare `\r` line endings, not CRLF.** The header/body separator is
`\r\r`, which is why `eml::AttachmentPart::new` looks for that and not for
`\r\n\r\n`. It holds for message blocks too: of 300 sampled `Attc` blocks, 297
are bare-CR. Split a part on `\r\n` and you get one very long line that looks
like a single `content-type` header, which is a convincing wrong answer — the
parts in fact carry `content-transfer-encoding` and `content-id` as well.

Headers are lower-case as written, and a part carries **no**
`content-disposition`. A parser that decides what is an attachment by looking
for one will classify every calendar attachment as body text and silently find
nothing; the content id is what marks an inline image. 45 of the 223 blocks are
themselves `multipart/mixed`, so the 222 events with blocks hold 331
attachments in total. By media type: 176 PDF, 57 PNG, 51 ICS, 19 JPEG, 11
`message/rfc822`, and a tail of Office and zip files.

`CalendarEvents_Categories` has one row per event — 1,526 rows, 1,526 distinct
record ids — whether or not a category is set, and every `Category_RecordID` in
this profile is NULL. The join row's existence therefore means nothing; only a
non-NULL `Category_RecordID` does. Behaviour with a category actually assigned
is untested here.

### 9.5 The `.olk15Event` sidecar

One file per row under `Events/<bucket>/<UUID>.olk15Event`, bucketed like
`Messages/`. File count matches row count exactly (1,526). Unlike block paths,
no `CalendarEvents.PathToDataFile` contains a percent escape — decode anyway,
per §8.

It is the `OLK15MESSAGE_FORMAT.md` §1 container with a different magic:
**`CRLC`** at 0x20 instead of `CRLM`. All 1,526 files satisfy that document's
size invariant `filesize == 0x28 + table_region + data_region`, so a parser
needs only its magic check relaxed. Each file carries 47–59 properties (median
54), 68 distinct tags across the corpus.

**The property ids are a different namespace from `.olk15Message`.** `0x0100001f`
is the subject in a message and the HTML body in an event. Reuse the container,
never the id map.

Verified by comparing every file against its own row, or against a corpus-wide
invariant. Counts are files carrying the tag:

| tag | type | files | meaning | evidence |
| --- | --- | --- | --- | --- |
| `0x00000003` | i32 | 1526 | `Record_RecordID` | equals the column, 1526/1526 |
| `0x13000003` | i32 | 1526 | start, **minutes since 1601** | equals `Calendar_StartDateUTC`, 1526/1526 |
| `0x14000003` | i32 | 1526 | end, same encoding | equals `Calendar_EndDateUTC`, 1526/1526 |
| `0x52010003` | i32 | 1526 | folder id | equals `Record_FolderID`, 1526/1526 |
| `0x20000003` | i32 | 1199 | attendee count | equals `Calendar_AttendeeCount` on all 1,196 non-zero rows |
| `0x1a000003` | i32 | 35 | master record id | equals `Calendar_MasterRecordID`, 35/35 |
| `0x1e000003` | i32 | 35 | recurrence id | equals `Calendar_RecurrenceID`, 35/35 |
| `0x00000048` | 16 B | 1526 | `Record_UUID`, raw GUID bytes | byte-equal to the column, 1526/1526 |
| `0x0400001e` | UTF-8 | 1526 | `Calendar_UID` | equals the column, 1526/1526 |
| `0x6700001e` | UTF-8 | 1526 | `Record_ExchangeOrEasId` | equals the column, 1526/1526 |
| `0x6800001e` | UTF-8 | 1526 | `Record_ExchangeChangeKey` | equals the column, 1526/1526 |
| `0x0a00001e` | UTF-8 | 1526 | message class | the constant `IPM.Appointment` |
| `0x0400004d`, `0x1800004d` | double | 1526 | `Record_ModDate` | 1525/1526 each |
| `0x1600004d` | double | 1492 | dismiss time | equals `Calendar_DismissTime`, 1492/1492 |
| `0x0300000b` | bool | 44 | recurring | present on exactly the 44 `Calendar_IsRecurring` rows |
| `0x0700000b` | bool | 1526 | **all-day** | true on 431 events — exactly the set that both starts at a UTC midnight and lasts a whole number of days; the 7 midnight-UTC starts it excludes are all 60 minutes long |
| `0x0900000b` | bool | 1526 | has reminder | true on exactly the 65 `Calendar_HasReminder` rows |
| `0x0a00000b` | bool | 1526 | is a meeting | true on exactly the 1,196 rows with `Calendar_AttendeeCount > 0` |
| `0x0b00000b` | bool | 1526 | organiser is this profile | true on exactly the 466 events whose `0x0100001e` address is one of this profile's own accounts |
| `0x1500000b`, `0x82000002` | bool, i16 | 1526 | online meeting | true / 1 on exactly the 400 events carrying a Teams join URL |
| `0x06000003` | i32 | 1526 | reminder lead time, minutes before start | values are 15 (1,225), 1080 (212), 10, 30, 0, 420, 60, 1440, 5, 2880, 41, 180 — Outlook's own defaults, 1080 being the 18 hours it uses for all-day events |
| `0x17000003`, `0x18000003` | i32 | 1526 | start and end in **local wall-clock time** | equal to the UTC pair on 554 events; elsewhere the difference is a whole-hour zone offset that follows daylight saving (§9.3) |
| `0x30010014` | i64 | 1526 | `Record_AccountUID` | equals the column; only two values in this profile |
| `0x1100000b` | bool | 1526 | allow new time proposal | matches the column on all 1,479 true rows |
| `0x0200001f` | UTF-16 | 1526 | **subject** | 1,152 values are exactly the `Message_NormalizedSubject` of some `Mail` row — the invitation |
| `0x0400001f` | UTF-16 | 1526 (1,094 non-empty) | **location** | 391 contain "teams", 270 "zoom", 7 "room"; median 23 chars |
| `0x0100001f` | UTF-16 | 1463 | **HTML body** | 1,461 of 1,463 begin with HTML markup; median 1.6k chars, max 158k |
| `0x0100001e` | UTF-8 | 1526 | organiser address | contains `@` on 1526/1526; `0x0b00000b` is true on exactly the events where this address is one of the profile's own, which identifies both at once |
| `0x0a00001f` | UTF-16 | 400 | Teams join URL | all 400 share the prefix `https://teams.microsoft.com/l/meetup-joi…` |
| `0x3000001f` | UTF-16 | 2 | JSON-LD travel reservation | begins `[{"type":"FlightReservation","@context":…` |
| `0x0b00000d` | sub-record | 1196 | **attendee list** | present on exactly the 1,196 rows with `Calendar_AttendeeCount > 0`; median 532 B, max 9.4 kB |
| `0x0e00000d`, `0x8200000d` | sub-record | 222 | attachment metadata | present on exactly the 222 events owning a `ClAt` block |

Unidentified, but with their shape measured, so the next reader starts from
something:

| tag | shape | note |
| --- | --- | --- |
| `0x0c000003` | i32, {1: 1316, 0: 209, 2: 1} | a three-valued enum; 0 clusters on non-all-day meetings |
| `0x1d000003` | i32, {0: 895, 1: 445, 2: 186} | three-valued; value 1 covers 404 of the 431 all-day events, so free/busy is the obvious guess and it is only a guess |
| `0x81000002` | i16, {3: 1494, 1: 32} | |
| `0x1400000b` | bool, true on 33 | overlaps `0x81000002 == 1` on 30 of 33, so the two are related but not the same |
| `0x03000003` | i32, {0: 1388, 128: 138} | a bitfield; bit 7 is set mostly on meetings this profile organised |
| `0x0d00000b` | bool, true on 71 | |
| `0x0f00000b` | bool, false on 11 | |
| `0x1600000b` | bool, true on 1 | |
| `0x0900000d`, `0x0f00000d` | sub-records on 1526 / 1436 files | ~690 B each |

Carrying no information in this profile, which is not the same as meaning
nothing: `0x05000003`, `0x07000003` and `0x1800000b` are 0 on every file,
`0x0e00000b` and `0x1000000b` are 0 on all 1,105 that have them, and
`0x0500001f` is one constant 15-character ASCII string across its 902 files.

Sub-records are the `0x000d` nesting of `OLK15MESSAGE_FORMAT.md` §4 — the
container rules carry over, the ids do not, so the attendee list needs its own
pass before it can be read.

One caution on the reminder pair. Every file carries a lead time (`0x06000003`),
but `Calendar_HasReminder` is set on only 65 rows, so that column cannot mean
"a reminder is configured". Nor is it "a reminder is still pending": only 29 of
the 65 are in the future. Its meaning is unresolved — read the lead time, and
treat the column as a flag of unknown intent.

A reader that wants a usable calendar therefore does what the mail path already
does: select from `CalendarEvents`, then open one sidecar per selected row.

---

## 10. Cautions

- Undocumented, unversioned in any public sense, and Microsoft can change it in
  any update. Validate `user_version`, validate that the columns you read still
  exist, and keep a fallback path.
- Reading requires Full Disk Access on modern macOS.
- Row counts here are one profile's and are illustrative only.
- `Message_NormalizedSubject` is not the display subject; it has the `RE:` /
  `FW:` prefix stripped. `Message_Preview` is capped at 255 characters. Both
  full values live in the sidecar file.
