# TimeFlip2 firmware observations

Behaviour measured on real hardware that the vendor spec does not describe, and in one case
contradicts. Everything here was observed directly, with the debug log rows to prove it; nothing is inferred from the protocol document.

This is the third source in the hierarchy set out in the root `CLAUDE.md`:
`docs/TimeFlip2 BLE Protocol v4.3.md` is authoritative, `docs/timeflip.md` describes this codebase's driver, and **this file records what the hardware actually does where the spec is silent**. Where this file and the spec disagree, the hardware wins, because these are measurements.

**Device under test.** Manufacturer `DI_LABS`, model `2.0`, hardware `TFv4.1`, firmware `FW_v3.64`, read from the Device Information service. Host macOS, CoreBluetooth. Measured 2026-08-01/02.

## The evidence file

[`timeflip2-firmware-evidence.sqlite`](timeflip2-firmware-evidence.sqlite) sits beside this document
and holds the debug log rows every claim below rests on. Every row id quoted here is a row in it.

**One clean run, start to finish.** 643 rows over 7m44s on 2026-08-02, from a database created empty
moments before, produced by the harness on this repo's `timeflip2-firmware-diagnosis` branch at
commit `0fa253d` with no code changes during the run. An earlier version of this file cited a
longer capture taken while the code was still being edited; it was replaced precisely because a
claim about firmware is worth less when the client was a moving target.

Original `debug_log_id` values and timestamps are carried over unchanged, so ordering by id is true
chronological order (the extract script verifies this rather than asserting it).

```
sqlite3 docs/timeflip2-firmware-evidence.sqlite \
  "SELECT debug_log_id, logged_at, tag, message FROM debug_log ORDER BY debug_log_id;"
```

| Tag | Meaning |
|---|---|
| `ble-tx` | bytes written to the device |
| `ble-rx` | bytes received from it, logged above every handler so nothing is filtered out |
| `face-task` | the app's own rename lifecycle, including the re-read ladder |
| `field` / `click` | the user action that started it |
| `scan` | one scanned advertisement: both names it carried, and the name being searched for |
| `device-name` | the name read on connect, and the name the device later reported |

To reproduce it, or to retest after a firmware update, see
[`FIRMWARE-DIAGNOSIS.md`](../FIRMWARE-DIAGNOSIS.md) on that branch.

---|---|
| `ble-tx` | bytes written to the device |
| `ble-rx` | bytes received from it |
| `face-task` | the app's own rename lifecycle |
| `field` / `click` | the user action that started it |
| `scan` | one scanned advertisement: both names it carried, and the name being searched for |
| `device-name` | the name read on connect, and the name the device later reported |

Checked in deliberately, at 60 KB. These measurements cost an evening of device time and several wrong conclusions along the way, and a claim about firmware behaviour is worth little without the trace behind it.

---

## 1. Renaming changes the GAP name but not the advertised name

Command `0x15` changes the GAP Device Name (`0x2A00`). It does **not** change the advertised local
name, which stays `TimeFlip v2.0` permanently. Seen on every rename tested, over two sessions and
eight different names.

In the clean run, before any rename, with nothing remembered (id 18):

```
connect scan matched: name=Zonker advert=TimeFlip v2.0 looking-for=nil
```

and after renaming that same device to `Wibble` (ids 585 to 651):

```
listed: name=Zonker advert=TimeFlip v2.0 looking-for=Wibble
```

`name=` is the GAP name and `advert=` the advertisement's local name. The advertised one is still
the factory string, and the GAP one is still the name from *before* the rename (see below).

That split is the single most consequential fact about renaming, because the two names are what a
scan matches on:

- Matching **only the GAP name** loses the device the moment it is renamed off "TimeFlip". On Apple
  platforms `CBPeripheral.name` is that value, so it is the obvious thing to filter on, and doing so
  is what made a renamed cube undiscoverable here (fixed; see `DeviceNameRules.matchesKnownDevice`).
- Matching **only the advertised name** always finds the hardware but can never show the user the
  name they chose.

So both are needed, for different jobs. `DeviceNameRules.matchesKnownDevice` checks both.

### The GAP name is one connection stale

`CBPeripheral.name` is cached by macOS and refreshed only when CoreBluetooth next connects and re-reads GAP. Straight after a rename it still reports the previous name. Polling it 120 times over 30 seconds within the same connection never saw it change.

The next connection does report it: `peripheralDidUpdateName(_:)` fires a second or two in, on
every rename tested. Ids 873 and 883 of the clean run are the whole mechanism in two lines:

```
09:20:01.788  device name read on connect: device=Zonker stored=Wibble
09:20:02.964  device reported a new name: Wibble
```

The connect-time read is the stale one and is correctly not adopted; the callback arrives 1.2s later
with the truth.

**Consequence for this app:** a name the app has written and the device has confirmed beats a connect-time read, because the read is the stale one. `AppState.shouldAdoptReportedName` implements that, taking the reported name only on a first pairing.

**Unresolved.** Whether the device applies a rename immediately or defers it cannot be determined from macOS, since the host only re-reads GAP on connect. Answering it needs a second BLE central with no cached record of the device.

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

`0x08` and `0x30` are write-only and *do* answer, so "write-only commands do not answer" is not the
rule. Which commands answer looks arbitrary.

The table was re-derived from the clean run rather than carried over, and reproduced exactly. One
detail confirms the reading: the stale payload sitting behind `0x09`, `0x0A` and `0x11` was
`01 02 …` in the first capture and `01 01 …` in the second, differing only in the lock byte, which
is what the leftover `0x10` status response should do.

For `0x15` this was checked exhaustively rather than assumed. It looked like a timing race, since the
client reads the result ~50 ms after the write while the device only narrates completion ~230 ms
later, so the read was repeated on a ladder. Clean run, ids 518 to 535:

```
09:19:12.898  write command ack <- 15 06 57 69 62 62 6C 65
09:19:12.952  commandResult -> 17 3A 5A 3B 14 3C 32 3D 32 00 ...
09:19:13.130  eventsData -> 4E 65 6D 65 20 73 65 74
09:19:13.251  0x15 commandResult re-read at  +250ms: 17 3A 5A 3B 14 ...
09:19:13.808  0x15 commandResult re-read at  +500ms: 17 3A 5A 3B 14 ...
09:19:14.889  0x15 commandResult re-read at +1000ms: 17 3A 5A 3B 14 ...
09:19:17.048  0x15 commandResult re-read at +2000ms: 17 3A 5A 3B 14 ...
```

`17 3A 5A 3B 14 3C 32 3D 32` is the response to `0x17` (read double-tap parameters), issued during
session setup six minutes earlier. It is still there two seconds after the rename and well after the
device has announced completion. It is not a race.

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

## Raising it with the vendor

Findings 1 to 3 are to be reported against `DI-GROUP/TimeFlip.Docs`. **Not yet filed** -- update this
line with the issue link once it is.

The request is that the spec describe the behaviour, not that the behaviour change. A guaranteed
stable advertised name is genuinely useful for scan filtering once documented rather than merely
observed, and the events-data narration would be a perfectly good completion signal if it were
supported rather than incidental.
