# The `.olk15Message` file format

Reverse-engineered 2026-09-15 against Outlook 16.103.2 on macOS, over 144 live
messages. Everything marked **verified** was cross-checked against either the
`Outlook.sqlite` row for the same message or the value Outlook returns for the
equivalent AppleScript property. Everything marked *(unidentified)* is structure
I can parse but cannot name.

Companions: `OLK15MSGSOURCE_FORMAT.md` for the raw-MIME sidecar that a minority
of messages also have, and `MAIL_SPEED_PLAN.md` §4.1, which is why this matters: these files
hold the subject, headers and body that the Apple event path charges roughly
330 ms per message to fetch. Parsing all 144 files in a 3-day window takes
**34 ms**, about 0.24 ms each.

One file per message, at `Mail.PathToDataFile` relative to the profile's `Data`
directory, e.g. `Messages/161/A1995331-….olk15Message`.

---

## 1. Container

All integers are little-endian unless stated. **Property tags are big-endian** —
that is the one exception and it is easy to get wrong.

```
offset  size  meaning
0x00    32    outer header (see below)
0x20     4    magic "CRLM"
0x24     4    checksum, u32                      (algorithm unidentified)
0x28     4    entry count, u32
0x2c     4    table region size, u32             (counted from 0x28)
0x30     4    data region size, u32
0x34     …    property table: count × 8 bytes
0x28+tbl …    data region: values, concatenated in table order
```

**Verified invariant**, exact on all 144 files:

```
filesize == 0x28 + table_region_size + data_region_size
```

Use it as the format check. A file that fails it is not this format, and the
parser should fall back rather than guess.

Each table entry is 8 bytes:

```
u32 big-endian     tag   = (property id << 16) | type
u32 little-endian  size  = value length in bytes
```

Values carry no padding and no offsets. The first value begins at
`0x28 + table_region_size`; each subsequent value begins where the previous one
ended. Entries are sorted by type, then by property id.

### Outer header

Mostly unidentified, and a parser does not need it — start at the magic and
validate with the size invariant.

| offset | observed |
| --- | --- |
| 0x00 | `0xdd0` (3536) on every file |
| 0x04, 0x08 | `1`, `1` on every file |
| 0x0c | small ascending integer, differs per message |
| 0x10 | `3` on every file |
| 0x14 | 0x79 or 0x7c |
| 0x18 | 8 bytes, varies *(unidentified)* |

---

## 2. Types

The type codes follow MAPI where they overlap, which is a useful mnemonic but
not a guarantee — treat this table as the contract, not the MAPI spec.

| type | size | meaning |
| --- | --- | --- |
| `0x0002` | 2 | int16 |
| `0x0003` | 4 or 8 | int32 (a few ids carry 8 bytes; read as two int32) |
| `0x0008` | var | binary blob *(unidentified; 22–57 bytes, starts `0x01`)* |
| `0x000b` | 1 | boolean |
| `0x000d` | var | nested sub-record — see §4 |
| `0x0014` | 8 | int64 |
| `0x001e` | var | UTF-8 string, NUL-terminated |
| `0x001f` | var | UTF-16LE string, NUL-terminated |
| `0x0020` | var | nested property collection, same tag/size encoding *(ids unidentified)* |
| `0x004d` | 8 | **IEEE 754 double: seconds since 2001-01-01 UTC** (Core Foundation absolute time / `NSDate` reference) |

`0x004d` is the one to be careful with. Read the 8 bytes as a `Double`, not an
integer, and add it to a 2001 epoch. Verified: property `0x0200004d` decoded to
2026-09-16 03:32:02 UTC, matching that row's `Message_TimeReceived` of
1789529522 exactly.

---

## 3. Properties worth knowing

Presence counts are out of the 144-message window.

### Identity and routing — verified against `Outlook.sqlite`

| tag | type | meaning | matches column |
| --- | --- | --- | --- |
| `0x00000003` | int32 | record id | `Record_RecordID` |
| `0x04000003` | int32 | message type | `Message_type` |
| `0x05000003` | int32 | message size | `Message_Size` |
| `0x52010003` | int32 | folder id | `Record_FolderID` |
| `0x30010014` | int64 | account uid | `Record_AccountUID` |

### Text — verified against AppleScript

| tag | type | meaning | present |
| --- | --- | --- | --- |
| `0x0100001f` | UTF-16 | **subject, as displayed** | 144/144 |
| `0x2a00001f` | UTF-16 | normalized subject (prefix stripped) | 144/144 |
| `0x2700001f` | UTF-16 | preview, **capped at 255 chars** | 144/144 |
| `0x1e00001f` | UTF-16 | **HTML body** | 144/144 |
| `0x6200001f` | UTF-16 | HTML body without the quoted chain | 144/144 |
| `0x2300001f` | UTF-16 | display-to line | — |
| `0x0400001e` | UTF-8 | **RFC822 headers** (headers only, no body) | 140/144 |
| `0x0200001e` | UTF-8 | `Message-ID` | 144/144 |
| `0x2200001e` | UTF-8 | `In-Reply-To` | — |
| `0x2400001e` | UTF-8 | `References` | — |
| `0x4000001e` | UTF-8 | message class, e.g. `IPM.Note` | — |

Three results that matter more than the table:

**`0x0100001f` is the display subject, 144/144 identical to AppleScript's
`subject`.** It is already decoded Unicode — no RFC 2047 encoded-words, no
header unfolding, and it is present even on meeting invites, which carry no
RFC822 headers at all. It supersedes both workarounds in `MAIL_SPEED_PLAN.md`
§4.1: the `Subject:` header parse and the `Message_MessageListData` blob walk.

**`0x1e00001f` is exactly AppleScript's `content`**, after normalizing `CRLF` to
`CR`. Outlook collapses the line endings on the way out; the file keeps `CRLF`.

**`0x6200001f` is the body worth indexing.** Measured 2026-09-16 over a
4,000-message random sample: present on **93.9%** of messages, and where
present a median of **26%** the size of `0x1e00001f`. In total, 87.1 MB of full
bodies against 28.7 MB de-quoted — **67% of stored body volume is quoted reply
chain**. Converted to text the gap widens to 74–82%, since the quoted chain
carries most of the markup too.

That matters beyond storage. Indexing the full body makes every message in a
thread match every term anyone in the thread ever wrote, so a 20-message thread
returns 20 undifferentiated hits for a word said once. `olsyncmail` now exports
this property to a `<stem>.olsync.json` sidecar beside each `.eml`, and
`olindexmail` builds its search text from it, falling back to the full body on
the ~6% that have none.

**There is no full plain-text body in the file.** `0x2700001f` is the 255-char
preview and equals the `Message_Preview` column, not `plain text content`.
Anything wanting plain text must derive it from `0x1e00001f`. Planner already
does: `MailSummaryPrompt.plainBody` falls back to `stripHTML(html)` on an empty
body, and `MailBodyFormatting.attributedString(html:plain:)` prefers the HTML.

`0x0400001e` matches AppleScript's `headers` except for the `Content-Type`
boundary, which Outlook rewrites when it serves them. The file holds the
original. Uses CR line endings and RFC822 folding, so unfold before parsing —
the same handling `MailHeaders` already applies.

### Timestamps — type `0x004d`

| tag | meaning |
| --- | --- |
| `0x0200004d` | **time received** (verified against `Message_TimeReceived`) |
| `0x0100004d` | time sent |
| `0x0400004d` | local modification time, sub-second precision |
| `0x1500004d`, `0x1a00004d` | *(unidentified)* |

---

## 4. Sub-records (type `0x000d`)

A message carries several. `0x0300000d` and `0x0600000d` hold the sender;
`0x1e00000d` and `0x1f00000d` hold recipients; `0x2100000d` is larger and looks
like the attachment table *(unidentified)*.

The preamble is about 0x23 bytes and I have not decoded it. The tail is
straightforward and is where the useful data lives — two length-prefixed
strings, in this order:

```
u32 length   UTF-8 SMTP address
u32 length   UTF-16LE display name      (length is in bytes, always even)
```

**Verified:** scanning `0x0300000d` for that pair recovered the sender's display
name and address on **144/144** messages, matching `Message_SenderList` and
`Message_SenderAddressList` exactly.

Because the preamble length is not pinned down, scan a small offset window
(0x1f–0x30) for the first u32 that yields a plausible UTF-8 address followed by
an even-length UTF-16 run, rather than hardcoding an offset.

---

## 5. Minimal parser

```python
import struct

def parse(data: bytes) -> dict[int, bytes]:
    if data[0x20:0x24] != b'CRLM':
        raise ValueError("not a CRLM record")
    _cksum, count, tbl, dsz = struct.unpack_from("<4I", data, 0x24)
    if 0x28 + tbl + dsz != len(data):
        raise ValueError("size mismatch")
    props, off, pos = {}, 0x34, 0x28 + tbl
    for _ in range(count):
        tag  = struct.unpack_from(">I", data, off)[0]      # big-endian
        size = struct.unpack_from("<I", data, off + 4)[0]  # little-endian
        props[tag] = data[pos:pos + size]
        off += 8
        pos += size
    return props

def text(props, tag):
    v = props.get(tag)
    if v is None:
        return None
    enc = 'utf-16-le' if (tag & 0xffff) == 0x1f else 'utf-8'
    return v.decode(enc, 'replace').rstrip('\x00')

SUBJECT, HTML_BODY, HEADERS = 0x0100001f, 0x1e00001f, 0x0400001e
```

Parsed 144/144 files with zero failures.

---

## 6. Cautions

- **Undocumented and unversioned.** Microsoft can change any of this in any
  update. Validate the magic and the size invariant on every file, and fall
  back to the Apple event path on any failure rather than guessing.
- **Read-only.** Outlook owns these files and is writing them while you read.
- **The same encoding appears in `Mail.Message_MessageListData`**, the database
  blob, with different property ids. The container rules in §1 carry over; the
  id map in §3 does not.
- **Messages with no `0x0400001e` are common, and `Message_type` does not
  identify them.** Corrected 2026-09-16 over a 3,000-message random sample
  (3,000/3,000 parsed): **534 (17.8%) carry no RFC822 header block**, against
  the 4/144 this survey originally saw. `Message_type` is `1165517645` =
  `0x4578634d` = `ExcM` on *all* 57,130 rows, so it is the generic
  Exchange-message tag and discriminates nothing. Use the message class
  (`0x4000001e`) instead. The population is mostly **sent mail**, not meeting
  invites:

  | class | count |
  | --- | --- |
  | `IPM.Note` | 366 (408 of the 534 are Sent Items) |
  | `IPM.Schedule.Meeting.Request` | 91 |
  | `IPM.Schedule.Meeting.Resp.Pos` | 61 |
  | `IPM.Schedule.Meeting.Canceled` | 11 |
  | `IPM.AbchPerson` | 4 |
  | `IPM.Schedule.Meeting.Resp.Neg` | 1 |

  All of them still have `0x0100001f`, so subject handling needs no special
  case, and `0x0300000d` still yields the sender — synthesizing `From`, `Date`
  and `Message-ID` from the sidecar reproduced Outlook's own values on every
  sent message checked. Header *parsing* is what needs the fallback.

- **A present header can still be empty.** Unsent drafts carry a bare `From:`
  with no value. Code that asks "is this field present?" before filling it in
  will skip them and emit a message with no sender; test for a non-empty value.
  Rare overall (0 of 2,466 sampled messages that had a header block) but normal
  within Drafts.
- The `0x0008`, `0x0020` and `0x2100000d` values are parseable as structure but
  unidentified. Nothing here depends on them.
