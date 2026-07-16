# TimeFlip Device Engineering Notes

This document captures how the TimeFlip2 puck exposes its BLE surface and how the macOS driver in `Sources/TimeFlipApp/` uses it. Use this as the architectural source when evolving the driver or building test doubles.

## 1. High-level model

- The device is a 12-facet accelerometer-based timer. All state is kept in volatile RAM and resets when the coin-cell is removed (vendor doc v4.3, rev 20.02.2022).
- BLE roles: the host is GATT client; the puck exposes one vendor service plus Battery (0x180F) and Device Information (0x180A).
- Authentication: every connection requires writing a six-ASCII-byte password to the Password characteristic; it resets after each disconnect. Default is `"000000"`.
- A “session” in the app is the ordered set of steps: radio readiness → discovery/connect → service/characteristic discovery → password write → notifications subscription → host-led initialization (time sync + status read) → steady event stream.

## 2. GATT surface (UUIDs)

Vendor service `F1196F50-71A4-11E6-BDF4-0800200C9A66` with characteristics:
- Events data `...51` (ASCII event log, R/N)
- Facets `...52` (current facet 1–12, 0 if undefined or bad password, R/N)
- Command result `...53` (20 B, R)
- Command `...54` (20 B, R/W; second byte echoes 0x02 on success, 0x01 on failure)
- Double tap `...55` (N; 1 B payload)
- System state `...56` (4 B, R/N; sync + hardware health)
- Password `...57` (W; 6 B ASCII)
- History `...58` (20 B, R/W/N)

Standard services:
- Battery Level `2A19` (1 B, R/N)
- Device Info `2A29/2A24/2A27/2A26/2A23` (R)

UUIDs and properties match the Swift constants in `TimeFlipUUIDs.swift` and the values published in the vendor protocol.

## 3. Command channel (F1196F54)

Each write is immediately read back from the same characteristic; the driver treats `[cmd, 0x02]` as success (vendor format). The driver also tolerates a lone `0x02` ACK seen on some firmware builds.

Opcode summary (from vendor spec and observed firmware):
- 0x04 lock mode on/off
- 0x05 set auto-pause minutes (u16, 0 disables)
- 0x06 pause mode on/off
- 0x07 read device time → result: `[0x07][unix seconds u64]` (vendor doc; some firmware historically returned 32-bit but current code expects 64-bit)
- 0x08 set device time (host sends 8 B unix seconds, big-endian per vendor doc v4.3; Swift now sends 8 B)
- 0x09 LED brightness 1–100 %
- 0x0A LED blink interval 5–60 s
- 0x10 status → result bytes: lock (0x01/0x02), pause (0x01/0x02 unless locked), auto-pause minutes (u16)
- 0x11 set facet color: facet id, then 16-bit R,G,B (Swift uses u16; spec allows up to 24 facets)
- 0x13 set task parameters: facet, mode (0 simple, 1 pomodoro), pomodoro seconds (u32)
- 0x14 read task parameters: returns facet, mode, pomodoro limit, and elapsed seconds (Swift picks the minimum of little- vs big-endian interpretations). The elapsed seconds value appears to be a running total (likely since start-of-day or since full history), not just the current interval.
- 0x15 set device name (len + ASCII)
- 0x16/0x17 read/write accelerometer double-tap registers
- 0x30 set new password (6 B)
- 0xFE reset task info; 0xFF factory reset

Swift driver currently issues: 0x05, 0x06, 0x08, 0x10, 0x11, 0x14. Remaining opcodes are understood but not yet exercised.

### Confirming a command actually took effect

The write-ack described above (`[cmd, 0x02]`) only confirms the device *accepted* the command —
it says nothing about the resulting state, and the protocol never pushes an unsolicited
notification when state changes from a command. Whether/how to confirm the actual state depends
on which command was sent — there's no single mechanism that covers all of them:

- **Commands with a dedicated state read-back**: 0x10 (status → lock/pause/auto-pause), 0x14
  (read task parameters), 0x17 (read double-tap registers), 0x07 (read device time). After
  writing the corresponding set command, issue the matching read and compare against what was
  requested before treating the change as applied — e.g. after `0x04 0x01` (lock on), send `0x10`
  and check the returned lock byte.
- **Commands with no read-back defined at all**: 0x09 (LED brightness), 0x0A (blink interval),
  0x11 (facet color). The vendor spec defines no command that reads these back — the write-ack
  is genuinely the only confirmation available for these three.
- **Commands where a read is impossible by nature**: 0x30 (set password) can't be read back over
  BLE for obvious reasons. Confirmation has to be functional instead — attempt a real login with
  the new password and only treat the rotation as successful if that login succeeds. This is
  already how `rotateDevicePassword`/`resetDevicePasswordToDefault` work, and is the model for any
  other command that turns out to need functional (rather than read-back) confirmation.

## 4. Event and notification semantics

- **Facet (`...52`)**: 1 B facet ID 1–12. `0` indicates undefined or rejected password. App updates active facet and seeds snapshots from this value.
- **Double tap (`...55`)**: 1 B; `<128` means facet, pause=off. `>=128` means pause=on and facet = value−128. Swift decodes this into `(facet, pause)` via `TimeFlipDoubleTapPayload`.
- **System state (`...56`)**: 4 B. Bytes 0–1 give sync state: `0000 ok`, `0100 factory reset`, `0201 time sync required`, `0202 facet color`, `0203 LED brightness`, `0204 blink interval`, `0205 task parameters`, `0206 auto-pause`. Bytes 2–3 give hardware status: `0000 ok`, `0201 accelerometer error`, `0202 flash error`, `0203 both`. The app surfaces this via `TimeFlipSystemState`.
- **Events data (`...51`)**: ASCII log strings (e.g., mock emits “flip facet=5”). Used for diagnostics only.
- **Battery (`2A19`)**: 1 B percent.

## 5. History stream (`...58`)

Commands:
- `0x01 <event#>`: single entry
- `0x02 <event#>`: sequential stream starting at event#, stopping at sentinel

Frame layout (spec v4.3 and observed firmware):
- Bytes 0–3: event ID (u32 big-endian). `0xFF..FF` asks for last.
- Byte 4: facet; `>127` means pause event for `(value−128)`; `66` signals accelerometer error; 0 is invalid.
- Bytes 5–12: flip timestamp, seconds since epoch, big-endian u64.
- Bytes 13–17: duration seconds, 5-byte little-endian (Swift keeps 5 bytes; some firmware only populates four).
- Remaining bytes (18–19) may hold previous-event pointer per doc; Swift ignores.
- Sentinel: all-zero payload (Swift checks first 17 zeros; spec shows 20 zeros).

Swift `fetchHistory` writes 0x02, increments the event number per frame, caps at 2048 frames, and stops on sentinel or parse failure. Parsed into `TimeFlipHistoryEntry {eventNumber?, facetID, startedAt, duration, isPaused}`.

### Live-record semantics (observed)
- The **last frame in every history dump is the current interval snapshot**, even when paused; its facet byte is `>=128` when paused (facet = byte−128).
- The device **reuses the same event number for the current interval** and refreshes its duration roughly every 5 s. That means duration updates arrive on the same `event_number`.
- Because of that reuse, the host **must not advance its cursor past the last frame**; otherwise refreshed durations for the in-progress interval would be missed.

### Host-side ingestion rules (macOS driver)
- On startup: load the logbook cursor from `integration_event_cursors`, fetch history starting at `cursor+1`, **withhold the last frame**, write all prior frames to the logbook, and use the withheld frame to set menu/UI state.
- On live facet/pause events: re-fetch history from the cursor, write all but the last frame to the logbook, and use the last for UI so repeated refreshes pick up duration/paused updates on the same event number.
- Cursor advancement:
  - Device cursor (identifier `device-history`) stays event-number based and advances only through the highest **written** (non-live) frame; keeps one interval behind the live record.
  - Integration cursors use logbook rowids (PK) to track delivery progress independently of device event numbers.

## 6. Connection and session lifecycle (macOS driver)

Sequence in `TimeFlipBLEDevice`:
1) `start()` creates the AsyncStream for events.
2) `connect() -> Bool`:
   - wait for Bluetooth `poweredOn`.
   - `scanAndConnect()` tries a broad scan (accepts name containing “timeflip” or advertised service); on timeout falls back to service-filtered scan. Timeout 12 s per mode.
   - On discovery, connect and discover services `TimeFlip`, `Battery`, `DeviceInfo`; then discover required characteristics (`...51–58`, battery, device info).
   - Returns `false` on any failure so the app can abort before login/initialization.
3) `login(password)` writes 6 bytes to Password. Accepts 0x01 or 0x02 in `command_result`; falls back to default password if user-provided fails.
4) `enableNotifications()` subscribes to facets, double tap, system state, events data, and battery.
5) `initializeSession(hostTime, desiredAutoPauseMinutes)` (only after successful login):
   - set device time via 0x08 to host wall clock,
   - refresh status (0x10) to seed lock/pause/autopause, and read system state,
   - normalize auto-pause to the host’s desired minutes (app preference, default 0),
   - refresh Device Info service fields,
   - `primeSnapshot()` reads system state, facet, and battery once.
6) Steady state: `CBPeripheralDelegate` translates characteristic updates into `TimeFlipEvent` cases and maintains `TimeFlipDeviceSnapshot`. Disconnection triggers `onDisconnect` so the app can auto-retry.

## 7. Entities in the app layer

- `TimeFlipEvent` (facetChanged, doubleTap, autoPauseMinutes, batteryLevel, systemState, deviceInfo, eventLog).
- `TimeFlipDeviceSnapshot` keeps the latest facet, pause/lock flags, auto-pause minutes, battery, system state, device time, and optional device info; serializable to JSON for debug.
- `TimeFlipHistoryEntry` models a history frame (eventNumber optional because the device can send zero).

These structures mirror the BLE payloads and are shared by the real and mock implementations.

## 8. Operational guidance

- Always write the password immediately after connecting; many commands silently fail otherwise, and facet notifications may return `0`.
- After any factory reset (`system_state` 0x0100) run the full sync: set time, push facet colors/LED settings, tasks, auto-pause.
- Treat accelerometer error sentinel (`side=66`) as a hard fault; app should surface it.
- When reading elapsed seconds via 0x14, prefer the non-zero value among little- and big-endian interpretations; firmware is inconsistent.
- History dumps can be large; enforce a frame cap (Swift uses 2048) and stop on all-zero frames (full 20-byte zero frame per vendor doc) to avoid hangs.

## 9. Known divergences / firmware quirks

- Password success code is ambiguously documented; real devices often return `0x02` for OK while the spec says `0x01`. Swift accepts both.
- Color command uses 16-bit per channel in practice; the spec examples sometimes imply 8-bit but accept wider values.
- Duration in history frames is five-byte little-endian per spec; some firmware seems to emit only four meaningful bytes. Be tolerant when parsing.
- Command 0x14 response endianness varies; choose the smallest non-zero elapsed value (Swift logic).

## 10. Minimal happy path (as implemented)

1) Scan (broad, then filtered) → connect; abort setup if `connect()` returns false.
2) Discover services/characteristics; require all TimeFlip chars.
3) Write password (`000000` fallback).
4) Subscribe to facet, double-tap, system-state, event log, battery.
5) Set device time (0x08), read status (0x10), normalize auto-pause, read device info, prime snapshot.
6) Stream notifications; on facet change, emit `facetChanged`; on double tap emit pause toggle; react to system/battery updates.
7) On demand, read history starting at cursor, stop on sentinel.

This flow matches the production driver (`TimeFlipBLEDevice.swift`) and the vendor v4.3 protocol notes.
