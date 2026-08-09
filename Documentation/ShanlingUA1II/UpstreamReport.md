# 给 pryid/shanling-control 的报告（草稿）

拟提交为 GitHub issue。发之前请你过目。

发送前需要替换的占位符：`<REPO-URL>`。

---

**标题**：UA1 II (0x3033) verified on real hardware — protocol confirmed, one endpoint-type correction

---

Thanks for publishing this — it's the only documentation of the Shanling
vendor protocol I could find anywhere, and the reverse-engineering of Eddict
Player saved me a lot of work.

`AUDIT.md` notes that only the UA4 was tested on real hardware. I've now
validated the **UA1 II (`20b1:3033`)** path against a physical device, on macOS,
in both directions: writes take effect and state reads come back.

Summary: **the protocol in `PROTOCOL.md` is correct.** One detail in the
transport layer is wrong, and there are two behaviours that aren't documented
and are easy to misread as "the protocol doesn't work".

## 1. Confirmed — everything in the protocol doc

All eight commands verified by writing a value and reading it back:

| Command | Setting | Range |
|---|---|---|
| `0x01` | Volume | 0–99 |
| `0x02` | Gain | 0 low / 1 high |
| `0x03` | Filter | 0–4 |
| `0x04` | Channel balance | **signed byte**, −12…12 |
| `0x06` | Brightness | 0–10 |
| `0x07` | Screen orientation | 0–3 |
| `0x09` | Screen timeout | seconds, 0 = never |
| `0x15` | Screen offset | **wire value = logical + 50** |

The 41-byte frame in `drivers/bulk41.py` matches the device's HID descriptor
exactly:

| `_packet41()` | Device descriptor |
|---|---|
| 41-byte write | `MaxOutputReportSize = 41` (report ID + 40) |
| `packet[0] = 1` | Report ID **1** |
| 9-byte read | `MaxInputReportSize = 9` (report ID + 8) |
| checksum computed with `byte0 = 0` | byte 0 is the report ID, not part of the payload |

The `+50` bias on screen offset and the signed byte for balance are both
correct — I hit both by accident before reading the doc carefully.

## 2. Correction — interface 2 uses interrupt endpoints, not bulk

`PROTOCOL.md` and the `bulk41` driver name describe interface 2 as bulk. On the
UA1 II both endpoints are **interrupt**:

```
Interface 2, class 0x03 (HID)
  EP 0x82  IN   interrupt, wMaxPacketSize 64, bInterval 1
  EP 0x03  OUT  interrupt, wMaxPacketSize 64, bInterval 1
```

For `hidapi` this makes no difference — it works either way. It matters for
anything going through raw USB: on macOS `IOUSBLib`'s `ReadPipeTO` /
`WritePipeTO` are documented as bulk-only and return `kIOReturnBadArgument`
(`0xE00002C2`) on an interrupt pipe; the plain `ReadPipe` / `WritePipe` must be
used instead. libusb users would need `interrupt_transfer` rather than
`bulk_transfer`.

I don't know whether other models genuinely use bulk here. If the UA4 does, the
naming is fine and only the UA1 II entry needs a note.

## 3. Undocumented — each request returns *two* reports

Every request is answered by a data frame **followed by a terminator frame**:

```
request page 1
  <- 01 55 AA 21 15 00 01 00 C9     data     (volume 21, gain 0, filter 1, balance 0)
  <- 01 00 00 00 00 00 00 00 00     terminator
```

**Both must be read.** If you read only the data frame and send the next
request, the leftover terminator is consumed first, every reply shifts one
position late, and from the second request onwards you appear to get empty
pages. It looks exactly like "the device doesn't answer this command", which is
what I concluded for a while.

Writes produce the same pair, with page `0x10` echoing the command and value.

This applies to `hidapi` as much as to raw USB — the extra report is queued
either way.

## 4. The device reports changes on its own

Pressing the buttons on the device emits an unsolicited `0x10` frame:

```
01 55 AA 10 01 14 ...    command 0x01 (volume), value 20
01 55 AA 10 01 15 ...    command 0x01 (volume), value 21
```

So a GUI can stay in sync with the hardware buttons without polling. I didn't
see this mentioned anywhere and it's genuinely useful.

## 5. Reply checksum

`PROTOCOL.md` documents the request checksum but not the reply's. It is:

```
frame[8] = ~(sum(frame[1..7])) & 0xFF
```

i.e. over the payload, excluding the report ID and the checksum byte itself.
Verified against all four state pages.

## 6. Write pacing

Consecutive writes need spacing. Measured on the UA1 II by writing A, waiting,
writing B, then reading back whether B took effect:

| Gap | Result |
|---|---|
| 100 ms | B dropped, 3/3 |
| 150 ms | B landed, 3/3 |
| 200 ms | B landed, 3/3 |

At 100 ms the second write is silently lost — `hid_write` still succeeds. Worth
a note for anything driving a slider.

## Suggested changes

Happy to open a PR — the minimal version is the endpoint type plus a note about
the double reply. I'd also suggest dropping `experimental=True` for `ua1-ii`.

## Unrelated note: the HID descriptor blocks WebHID

Not a bug in this project, but it may interest you if a browser UI was ever on
the cards.

The vendor channel's top-level collection is declared as Generic Desktop /
**System Control** (`0x01`/`0x80`). Chromium treats usages `0x80`–`0x8F` as
always-protected — `IsAlwaysProtected()` in
`services/device/public/cpp/hid/hid_report_utils.cc`, no exemption by report
type — so WebHID silently drops report ID 1 in both directions. The device still
appears in the chooser (its Consumer Control collection is unprotected), which
makes the failure quite confusing. WebUSB is out too: the device exposes only
audio and HID interfaces, both in WebUSB's protected-class list, so
`claimInterface()` can never succeed.

If Shanling ever revises the firmware, declaring that collection under a
vendor-defined usage page (`0xFF00`+) would make it work in the browser
unchanged — vendor pages are on no protection list. Probably worth passing on if
you have a channel to them.

## Environment

- Shanling UA1 II, firmware 01.00.00, `20b1:3033`
- macOS 26, talking to interface 2 through `IOHIDManager` — no root, no
  driver, and audio keeps playing throughout
- My implementation and full notes: <REPO-URL>
