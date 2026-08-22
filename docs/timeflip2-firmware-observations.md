# TimeFlip2 firmware observations

Behaviour measured on real hardware that the vendor spec does not describe, and in one case contradicts. Everything here was observed directly, with the debug log rows to prove it; nothing is inferred from the protocol document.

This is the third source in the hierarchy set out in the root `CLAUDE.md`: `docs/TimeFlip2 BLE Protocol v4.3.md` is authoritative, `docs/timeflip.md` describes this codebase's driver, and **this file records what the hardware actually does where the spec is silent**. Where this file and the spec disagree, the hardware wins, because these are measurements.

**Device under test.** Manufacturer `DI_LABS`, model `2.0`, hardware `TFv4.1`, firmware `FW_v3.64`, read from the Device Information service. Host macOS, CoreBluetooth. Measured 2026-08-01/02, and findings 4 and 5 on the same cube on 2026-08-17. Finding 7 is older traffic from the same cube, 2026-07-28 to 2026-08-14, recorded by the archived app rather than this one. Those four values are no longer only the archive's: finding 5 is this app reading them itself, and they came back identical.

## The evidence file

[`timeflip2-firmware-evidence.sqlite`](timeflip2-firmware-evidence.sqlite) sits beside this document and holds the debug log rows every claim below rests on. Every row id quoted here is a row in it.

753 rows in one `debug_log` table, carrying the source database's original `debug_log_id` values and timestamps, so ordering by id is true chronological order (verified: no row's timestamp precedes the row before it). It covers the rename history across the whole test session **plus one complete, unedited BLE trace** of a connect-and-rename from id 6716, so the acknowledgement claims can be checked against a full sequence rather than a flattering selection.

Rows 356 to 379 are finding 4, added on 2026-08-17 from a scripted run: the whole of two login attempts, both PINs and both answers, unedited. They come from the test database, which every run rebuilds from the DDL -- so without copying them here the evidence for that finding would have been destroyed by the next run.

Rows 309 to 319 are finding 5, added the same day from a driven run, and copied for the same reason: the accepted login, the pairing it wrote, and the four Device Information reads that followed, with the raw bytes of each.

Rows 340 to 356 and 384 to 399 are finding 6, from the same day: the `0xFF` write and its acknowledgement, the silence that followed it, and then the login two minutes later that proves the wipe took by being accepted on the vendor PIN. The gap between rows 355 and 356 is the finding — nothing was written in it because nothing happened.

Rows 14520 to 14534 and 19557 to 19580 are finding 7, and they are the odd ones out here: they come from the **archived app's own production database**, not from a scripted run of this one, because the charge is the one thing the rebuild had never read at the time the finding was written. Both stretches are unedited runs of consecutive ids. The first is a connect sequence with the battery read inside it; the second is seven minutes in which nothing was asked for and values arrived anyway.

```
sqlite3 docs/timeflip2-firmware-evidence.sqlite \
  "SELECT debug_log_id, logged_at, tag, message FROM debug_log ORDER BY debug_log_id;"
```

| Tag | Meaning |
|---|---|
| `ble-tx` | bytes written to the device |
| `ble-rx` | bytes received from it |
| `face-task` | the app's own rename lifecycle |
| `field` / `click` | the user action that started it |
| `scan` | one scanned advertisement: both names it carried, and the name being searched for |
| `device-name` | the name read on connect, and the name the device later reported |
| `login` | reaching a cube and presenting a PIN: each attempt, and what the cube made of it |
| `battery` | the charge, as the archived app recorded every reading it received |
| `conn-phase` | how long a step of the archived app's connect sequence took |
| `hist-*` | its history fetches, which are the only other traffic in the quiet window of finding 7 |

Checked in deliberately, at 60 KB. These measurements cost an evening of device time and several wrong conclusions along the way, and a claim about firmware behaviour is worth little without the trace behind it.

---

## 1. Renaming changes the GAP name but not the advertised name

Command `0x15` changes the GAP Device Name (`0x2A00`). It does **not** change the advertised local name, which stays `TimeFlip v2.0` permanently. Confirmed across seven renames.

That split is the single most consequential fact about renaming, because the two names are what a scan matches on:

- Matching **only the GAP name** loses the device the moment it is renamed off "TimeFlip". On Apple  platforms `CBPeripheral.name` is that value, so it is the obvious thing to filter on, and doing so  is what made a renamed cube undiscoverable here (fixed; see `DeviceNameRules.matchesKnownDevice`).
- Matching **only the advertised name** always finds the hardware but can never show the user the  name they chose.

So both are needed, for different jobs. `DeviceNameRules.matchesKnownDevice` checks both.

### The GAP name is one connection stale

`CBPeripheral.name` is cached by macOS and refreshed only when CoreBluetooth next connects and re-reads GAP. Straight after a rename it still reports the previous name. Polling it 120 times over 30 seconds within the same connection never saw it change.

The next connection does report it: `peripheralDidUpdateName(_:)` fires about two seconds in, on every rename tested. That callback is wired up and is what corrects the name a first pairing adopts from the stale cache.

**Consequence for this app:** a name the app has written and the device has confirmed beats a connect-time read, because the read is the stale one. `AppState.shouldAdoptReportedName` implements that, taking the reported name only on a first pairing.

**Unresolved.** Whether the device applies a rename immediately or defers it cannot be determined from macOS, since the host only re-reads GAP on connect. Answering it needs a second BLE central with no cached record of the device.

### Forcing the new name to appear

There is no way to make the device advertise the new name, but the reported name can be refreshed on demand rather than waited out, by deliberately spending the connection that refreshes it:

1. Rename the device.
2. **Forget Device**, which drops the connection.
3. **Scan for Devices**.
4. Click the row, which is **still showing the old name** (the list renders `peripheral.name`, the stale GAP value, falling back to the advertised name only when that is absent).
5. Once paired, the Name row shows the new name.

Step 4 is the step that looks wrong and is not: the peripheral identifier is the same cube whatever name is against it, so the connection proceeds and `peripheralDidUpdateName` then delivers the real name a second or two in.

This is written up for users under "Renaming Your Device" in [`configuration.md`](configuration.md). It is a workaround for the device's behaviour, not a fix, and it should stay in the documentation until a firmware release makes it unnecessary.

---

## 2. Only some commands update the command result characteristic

The spec describes the command result characteristic as carrying `0xXX 0xYY`, the command number and an error value, with no suggestion that this is optional. In practice a good number of commands never write to it at all, leaving whatever the previous command left there.

| Command | events data narration | command result |
|---|---|---|
| `0x07` get time | `get system time` | updated (`07 00 …`) |
| `0x08` set time | `set system time` | updated (`02`) |
| `0x10` status | none | updated (`01 02 …`) |
| `0x17` read double-tap | `read acc setting` | updated (`17 3A …`) |
| `0x30` set password | `password set` | updated (`02`) |
| `0x09` LED brightness | `set brightness LEDs` | **never updated** |
| `0x0A` blink period | `set blinking period` | **never updated** |
| `0x11` face colour | `set color` | **never updated** |
| `0x15` set name | `Neme set` | **never updated** |

`0x08` and `0x30` are write-only and *do* answer, so "write-only commands do not answer" is not the rule. Which commands answer looks arbitrary.

For `0x15` this was checked exhaustively rather than assumed: after a rename the characteristic was re-read at +250 ms, +500 ms, +1 s and +2 s, and every read returned the stale `0x17` response, well after the device had announced completion. It is not a timing race.

**Consequence for this app, and it is a real defect.** `TimeFlipBLEDevice.performCommand` writes, reads the command result, and validates it only when the response is one or two bytes long:

```swift
if response.count == 2, response.first == cmd { ...status check... }
else if response.count == 1 { ...status check... }
```

A stale 20-byte response from an unrelated command matches neither branch and is returned as success. So `0x04`, `0x09`, `0x0A`, `0x11` and `0x15` are all effectively write-blind while appearing verified. A single session start does this twelve times over for face colours alone.

---

## 3. Every command is narrated on the events data characteristic

Undocumented, and the only completion signal present for **all** commands, arriving 40-240 ms after the write. Plain ASCII on `F1196F51-71A4-11E6-BDF4-0800200C9A66`:

| Bytes | ASCII |
|---|---|
| `73 65 74 20 73 79 73 74 65 6D 20 74 69 6D 65` | `set system time` |
| `67 65 74 20 73 79 73 74 65 6D 20 74 69 6D 65` | `get system time` |
| `73 65 74 20 62 72 69 67 68 74 6E 65 73 73 20 4C 45 44 73` | `set brightness LEDs` |
| `73 65 74 20 62 6C 69 6E 6B 69 6E 67 20 70 65 72 69 6F 64` | `set blinking period` |
| `73 65 74 20 63 6F 6C 6F 72` | `set color` |
| `72 65 61 64 20 61 63 63 20 73 65 74 74 69 6E 67` | `read acc setting` |
| `72 65 61 64 20 68 69 73 74 6F 72 79` | `read history` |
| `67 65 74 20 68 69 73 74 6F 72 79` | `get history` |
| `70 61 73 73 77 6F 72 64 20 73 65 74` | `password set` |
| `4E 65 6D 65 20 73 65 74` | `Neme set` (sic) |

The spec documents this characteristic as carrying event data, not command narration, so the strings are presumably debug output the firmware never stopped emitting. That makes them a fragile thing to depend on: a future firmware could remove them without considering it a breaking change.

**Possible use.** It is the only way to know a `0x15`, `0x09`, `0x0A` or `0x11` actually completed. Worth considering as a confirmation signal, with the caveat above, and worth raising with the vendor so it either becomes supported or is replaced by a proper command result.

---

---

## 4. The password check answers `0x02` for a correct PIN, not `0x01`

The spec is explicit and it is wrong. Section 4, on the password characteristic:

> The result of the password check will be written to the command result output characteristic in the first (high) byte of the massive: 0x01 means the password is correct, 0x02 - the password is wrong.

The hardware does the opposite. **`0x02` is acceptance and `0x01` is refusal**, measured on 2026-08-17 across two logins to one cube, seconds apart, one of each outcome (rows 361 to 375):

| Time | Direction | Bytes | Outcome |
|---|---|---|---|
| 05:47:55.098 | `ble-tx` | `30 30 30 30 30 30` (`000000`) | the vendor default |
| 05:47:55.243 | `ble-rx` | `01` | **refused** -- the cube was not on the default |
| 05:47:58.426 | `ble-tx` | `31 32 33 34 35 36` (`123456`) | the PIN the cube was actually on |
| 05:47:58.543 | `ble-rx` | `02` | **accepted** -- every command afterwards worked |

The two are in one trace, from one cube, three seconds apart, so this is not a reading taken under different conditions and compared: the same characteristic answered both PINs and gave different bytes for the one that worked and the one that did not.

The archive reached the same conclusion by logging both outcomes (see `TimeFlipBLEDevice.attemptLogin`, whose comment says "vendor doc v4.3 states 0x01=correct/0x02=wrong, but real hardware observed here does the opposite"). This is that claim measured again on a rebuilt driver, and written down where the other measurements are, because a comment in an archived class is not somewhere anybody would look.

**Consequence for this app, and it is the most load-bearing byte in the feature.** Implemented from the spec, every correct PIN is refused and every wrong one accepted. `DeviceLoginRules.verdict` reads it the measured way round and `Tests/Scripted/51-device-connect.sh` asserts on the raw `commandResult: 02`, so a firmware release that ever moves to match the document fails a check rather than silently letting the wrong cube in.

### What the characteristics report about themselves

Also from those rows, and worth having because it settles how the write must be made: the password characteristic's properties are `0x08`, write-with-response only, and the command result's are `0x12`, read plus notify. So `.withResponse` is not a choice about reliability here -- it is the only thing the characteristic supports -- and the answer can be read or subscribed to.

### Timings

For sizing timeouts, from the same trace: connect 1.03s, service and characteristic discovery 0.99s, the write acknowledged 85ms later, the answer read 60ms after that. A refusal, a one-second settle, a reconnect and a second PIN accepted took 5.46s end to end -- consistent with the archive's 5.4s worst case for scan-and-link across 36 connects.

---

## 5. The Device Information strings are exact length, not padded to 20 bytes

Rows 313 to 319. The spec's Tab. 1 gives all four Device Information characteristics a size of **20 bytes**; the cube returns each one at its natural length instead, with no NUL padding and no trailing whitespace:

| Characteristic | UUID | Bytes returned | Value |
|---|---|---|---|
| Manufacturer Name String | `0x2A29` | 7 | `DI_LABS` |
| Model Number String | `0x2A24` | 3 | `2.0` |
| Hardware Revision String | `0x2A27` | 6 | `TFv4.1` |
| Firmware Revision String | `0x2A26` | 8 | `FW_v3.64` |

So the 20 in the spec is the field's **maximum**, not its transfer size. The archive's `readString` did a bare `String(data:encoding:)` with no padding handling and was correct on this firmware for exactly that reason.

**`DeviceInfoRules.reported` strips trailing NULs anyway**, and that is deliberate rather than redundant: what is measured here is one cube on one firmware build, and a build that did pad to the documented width would produce strings that compare unequal to themselves and draw labels wider than their words, with nothing on screen to say why. The strip costs nothing when there is nothing to strip.

### All four answered, and quickly

The whole phase -- discovering the service, then four reads -- took **354ms** (row 313 at `14:33:07.966`, row 318 at `14:33:08.320`), against the 10s deadline `DeviceLogin.infoTimeoutSeconds` allows. The first read cost 171ms including discovery; the remaining three came back at 61, 60 and 60ms. This cube exposes the service and answers every one of the four, so the app's handling of a partial answer is untested on hardware.

### They were read after a login, and only after one

Row 313 follows row 309 (`PIN accepted`) and row 312 (`Paired with`), which is the ordering the feature is built on: the pairing is written before these reads start, so nothing about them can delay or fail it. Standard GATT places no authentication on `0x180A`, so these should answer with no PIN presented at all -- but **that has not been measured**, because the app has never asked for them in any other state. Nothing in the app depends on it either way.

---

## 6. A factory reset does **not** drop the connection

Rows 340 to 356, and 384 to 399. `0xFF` was written and acknowledged at `17:54:22.730`, and the link then **stayed up for the whole 104 seconds** somebody watched it — no disconnect, no notification, nothing at all on any characteristic. The next row in the log is a human closing the window.

This contradicts what the archive assumed. `TimeFlipBLEDevice.factoryReset` describes the cube as rebooting, and `ApplicationDelegate` was built around the drop that reboot causes: it armed a confirmation window, waited for the disconnect, and reconnected from there. On this firmware that disconnect never arrives.

**The wipe itself worked perfectly.** That is the other half of the measurement, and the two together are what make this worth writing down:

| | PIN presented | Result |
|---|---|---|
| Before the reset (`17:54:14`) | `000000` | refused |
| Before the reset (`17:54:17`) | `123456` | **accepted** |
| After the reset (`17:56:28`) | `000000` | **accepted** |

The cube was on the app's PIN, and afterwards it was back on the vendor default — so `0xFF` erased it exactly as documented. What failed was the app noticing, and it failed silently: a reset that had genuinely happened sat unconfirmed until the window timed out.

**Consequence for this app.** `BluetoothRadio.factoryReset` no longer waits for a drop. Once the write is acknowledged it lets go of the link itself and then goes looking for the cube on the vendor PIN, which covers both firmwares — one that severs the connection is still handled by `didDisconnectPeripheral`, and one that does not is disconnected deliberately. Waiting on the device to do it was the whole bug.

### How long the wipe takes, and why one retry is not enough

Measured twice on the fixed code, both times by presenting the vendor PIN every three seconds until it was accepted:

| Run | `0xFF` acknowledged | Attempts refused | Accepted | Wipe took |
|---|---|---|---|---|
| `18:06` | `13.566` | 1 (at `18.955`) | `22.075` | **~8.5s** |
| `18:08` | `31.704` | 2 (at `36.710`, `39.833`) | `42.894` | **~11s** |

So the cube goes on answering the *old* PIN for several seconds after acknowledging the reset — it is not erased when the write returns, and it does not stop answering while it erases. A single confirmation attempt, however well timed, would have failed both runs and reported a wipe that had in fact happened. The retry loop is the feature, not a safety net.

**What is still not known** is whether the cube reboots at all, or merely erases in place. Nothing observable here distinguishes them: no disconnect, and the app was not watching the System State characteristic (`F1196F56`), which is where the archive says a `0x01 0x00` notification would appear if one does.

## 7. The battery level is pushed only when it changes, and it changes constantly

Battery Level (`0x2A19`) is listed in the spec as read and notify, with nothing said about when a notification arrives. Measured across eleven days of the archived app's own BLE trace (2026-08-02 to 2026-08-13, the same cube), it is **on change, and only on change**:

| | | |
|---|---|---|
| Values that answered a read the app made | 13 | 10 of them repeated the level already held |
| Values the cube volunteered | 2,834 | **none** repeated the level already held |

Not one unsolicited value in 2,834 restated something the host already knew, so a notification *is* a change. The ten repeats are all on the other line, and they are what a read is for: a cube asked at the start of a connection usually answers with the same level it had at the end of the last one. The three that did not are the charge having moved while the app was away.

The counts come from replaying the trace rather than from a single query, since a value has to be attributed to a read or to the cube by what preceded it. The rows themselves:

```sql
SELECT COUNT(*) FROM debug_log WHERE tag='ble-tx' AND message = 'read request batteryLevel';
SELECT COUNT(*) FROM debug_log WHERE tag='ble-rx' AND message LIKE 'batteryLevel -> %';
```

**Match the value rows exactly.** `LIKE '%atteryLevel%'` also matches the discovery and subscription rows the trace writes once per connection (`characteristics on batteryService: batteryLevel`, `notify on batteryLevel`), which is 26 rows that are not readings and which inflated this table's first draft.

**So a subscription alone is not enough.** Rows 14520 to 14534 are why: a connect sequence in which the app reads the level (`14528`, answered at `14529` with `63`, which is hex for 99%). Without that read, a freshly connected app has no figure at all until the charge next moves, and the gaps between moves ran to over an hour. Reading once on connecting and subscribing afterwards is what covers both.

### The level dithers across one percent, and each waver is a notification

Rows 19557 to 19580, seven minutes of an ordinary connected session. The only thing the app asked for in it is a history fetch at `17:51:48`; everything after that arrived unasked:

```
17:53:08  batteryLevel -> 63      99%
17:53:10  batteryLevel -> 62      98%
17:56:02  batteryLevel -> 63      99%
17:56:04  batteryLevel -> 62      98%
17:56:16  batteryLevel -> 63      99%
17:56:18  batteryLevel -> 62      98%
17:56:42  batteryLevel -> 63      99%
17:56:44  batteryLevel -> 62      98%
```

Always the same two adjacent values, always about two seconds apart, in bursts with minutes of silence between them. Over the whole trace the gaps fall out as 1,108 under 3s, 891 at 3-10s, 583 at 10-60s, 189 at 1-5m, 60 at 5-60m and 15 over an hour: a median of 4 seconds, and a quarter of them at exactly the 2 seconds a dithering pair takes.

**While the link is actually up, that is a value every 11 seconds.** Taking every gap of two minutes or less as time connected gives 8.3 hours across the trace and 326 values an hour within it, and the figure holds across the three days with enough traffic to measure separately: 329, 278 and 355 an hour.

**The charge itself barely moved.** The app's own `battery` rows, which go back further than the trace, put it at 100% on 2026-07-28 and 98% on 2026-08-14; on 2026-08-13 alone the cube reported 2,168 values while never saying anything other than 98 or 99. The volume is not a battery running down, it is a reading that cannot settle.

**Consequence for this app.** Neither the figure on screen nor the low-battery warning can be driven straight off a reading. `BatteryRules.shown` holds the lower of the two adjacent values and adopts a higher one only once a reading climbs two percent clear of it, so a dithering cube draws one steady figure; `BatteryRules.latched` keeps the archive's five-point recovery margin so the warning does not arm and disarm twice a second at the threshold. `BluetoothRadio` logs a `battery` row only when the answer moves, which is why the app's own log will not reproduce the counts above -- the raw values are all still there under `ble-rx`.

---

---

## Raised with the vendor

Findings 1 to 3 are the subject of an issue against `DI-GROUP/TimeFlip.Docs`. The request is that the spec describe them, not that the behaviour change: a guaranteed-stable advertised name is genuinely useful for scan filtering once documented, rather than merely observed.

**Finding 4 is different in kind and should be raised separately.** The other three are behaviour the spec is silent about; this one is a documented statement that is the wrong way round, and it is the sort of error that costs somebody a day. Either the firmware or the document is wrong, and the vendor is the only one who can say which was intended.

**Finding 6 is worth raising too**, and it is a question rather than a correction: the spec does not say what a client should observe after `0xFF`, and on this firmware the answer is *nothing at all* — the command is acknowledged, the device is genuinely erased, and the connection carries on as though it had not been. Any client that waits for the device to react is waiting for something that never comes. A single documented signal, on the System State characteristic or as a disconnect, would make a reset confirmable without a reconnect.
