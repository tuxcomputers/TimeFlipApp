# TODO: mock device parity and realistic timing

Working checklist for making `MockTimeFlipDevice` behave like the real hardware: every function the
real device offers, and delays that vary the way a radio link does instead of returning instantly.

**This file is the handover.** Tick items as they land; anything unticked is where a resumed session
picks up. Design decisions already settled are recorded below so they don't get relitigated.

## Excluded, deliberately

- **Factory reset.** Not being modelled. `factoryReset` isn't on `TimeFlipSessionManaging` at all --
  only on `TimeFlipBLEDevice` -- so modelling it means widening the protocol, not just adding a mock
  method. `Bench/02b` therefore stays a device-only checklist. (Its *timing* is now measured, see
  below; that's separate from modelling it.)

**No longer excluded:** the owner released the device on 2026-07-31 ("feel free to use it to check
timings of reset etc") and is building the event history up deliberately to give the per-record
figure a real sample. The earlier "no reset, no full-history dump" restriction is lifted.

## Settled design decisions

1. **Ranges, not fixed delays.** `DelayRange { lower, upper }`, sampled uniformly per call. A run of
   history records comes back e.g. 184ms, 198ms, 163ms rather than the same figure repeatedly, which
   is both what the device does and what stops a caller depending on a constant.
2. **Per record, not per fetch.** History charges one draw *per record* on top of a fixed
   command-round-trip cost, so a fifty-record backlog is fifty independent delays.
3. **Seeded randomness.** A `SeededGenerator` on the mock, seed settable via `Configuration`. Random
   delays must not make a failure unreproducible: same seed, same sequence, replayable failure.
4. **`.instant` stays the default.** Every existing test and the app itself are unaffected unless they
   opt in to `.realistic()`.
5. **Latency charged before the guards.** A rejected command still costs a round trip on real
   hardware, so the caller waits either way.
6. **Spreads are provisional.** The centres came from second-resolution `debug_log`, estimated from
   how often a pair of rows straddled a second boundary -- an aggregate, which gives no spread. The
   +/-20% widths are assumed, not observed, and flagged as such in the code.

## Checklist

Commits so far: `b50f9d5` timing mechanism, `480e637` readDeviceTime, plus the password pair below.

### Timing mechanism

- [x] `DelayRange` with `lower`/`upper`, `.none`, `.fixed`, `.milliseconds`, `scaled(by:)`
- [x] `sample(using:)` drawing uniformly from a supplied generator
- [x] `Latency` converted from fixed `Duration`s to `DelayRange`s
- [x] `historyPerEntry` renamed `historyPerRecord`, sampled per record in `fetchHistory`
- [x] `waitForRadio` samples a range rather than sleeping a fixed span
- [x] `SeededGenerator` (SplitMix64) + `delayGenerator` / `sampledDelays` stored properties
- [x] `Configuration.randomSeed`, fixed by default so runs are reproducible
- [x] Expose the drawn delays for assertions via `sampledDelays` (no clear helper yet -- add one if a
      test ever needs to measure a second phase of the same session in isolation)

### Functions the real device has and the mock doesn't

Delta taken from `TimeFlipBLEDevice`. Transport internals are **not** in scope -- `centralManager*`,
`peripheral`, `handleMainDisconnect`, `scheduleTimeout`, `cancelTimeout`, `hexString`, `withLock`,
`test` are CoreBluetooth plumbing, not device capabilities.

- [x] `readDeviceTime() async -> Date?`
- [x] `rotateDevicePassword() async -> String?`
- [x] `resetDevicePasswordToDefault() async -> Bool` (password reset, *not* factory reset -- history
      and pairing untouched, asserted by a test. Say if "except the reset" was meant to cover this.)
- [x] `startDiscoveryScan(filterToTimeFlip: Bool) async`
- [x] `stopDiscoveryScan()`
- [x] `connectToDiscoveredDevice(id: UUID, password: String) async -> DeviceConnectOutcome`
- [x] `cancelConnectionAttempt()`
- [x] Discovery emits `onDeviceDiscovered` / `onDiscoveryScanStopped`, staged via `discoverableDevices`

### Tests

- [x] Same seed produces the same delay sequence; different seeds differ
- [x] Every sampled delay lies within its declared range
- [x] A history fetch draws exactly one delay per record plus one for the command round trip
- [x] Per-record delays are not all identical (the point of the range)
- [x] `.instant` really is instant, and remains the default; a rejected command still costs a trip
- [x] A workflow using the new discovery/pairing functions (`Workflows/W05-pairing.swift`)

### Instrumentation added so the measurement is possible at all (2026-07-31)

Commits `fdf51e2`, `69c6266`. Three operations had no measurable duration before this, which is why
they were listed as unmeasured rather than merely imprecise:

- `connect` / `enableNotifications` / `initializeSession` logged only to `os_log`, never to
  `debug_log`. Now bracketed by the `conn-phase` tag, with `connect` split into radio-power,
  scan+link and characteristic discovery so a slow connect can be attributed.
- `resetDevicePasswordToDefault` and `factoryReset` logged only their *completion*, with no start
  marker anywhere. Both now log a start, and all three password/reset operations self-report their
  0x30/0xFF write and their confirming re-login separately.
- History frames had no per-frame timing. The `hist-time` tag reports the command round trip and
  every inter-frame gap, accumulated in memory and emitted as one row -- a row per frame would
  insert into SQLite inside the gap being measured.

Spans use `ContinuousClock`, not `Date`: a wall-clock adjustment mid-connect would corrupt them.

Extraction script (scratchpad, promote to `scripts/` if it earns its keep):
`measure_timings.py [db] [--since ISO8601]`, which reports n/min/p50/max/mean per leg and suggests a
5th-95th-percentile `DelayRange`. It warns loudly if the DB predates `f20ca37` and has no
milliseconds, since every figure would silently quantise to whole seconds.

### Measuring the password-set timing on the real device (tonight)

Owner asked for this specifically, flipping between the factory default and the dev PIN. Both values
are known (`000000` / `123456`), so a half-completed rotation can only leave the cube on one of two
PINs -- owner has said they'll try each if `config.json` ends up wrong, so there's no lock-out risk.

The two operations are triggered only from the UI, so this needs the app driven with the owner
hands-off (root `CLAUDE.md`'s live-interaction ritual):

- **Forget Device** -> `resetDevicePasswordToDefault()` -> device back to `000000`
- **Scan, tap the device, pair** -> `rotateDevicePassword()` -> device to `123456`
  (rotation runs *only* in the pairing flow -- `ApplicationDelegate:708`, `skipConnect` -- routine
  reconnects reuse the stored password, so a plain restart will not exercise it)

Pre-requisite: **rebuild and relaunch the app first**. Millisecond `logged_at` landed in `f20ca37`,
but the running binary predates it, so the timings would come back at second resolution again.

Legs to extract from `debug_log` (all already logged, tag `TimeFlip`):

- `Rotating device password to: ...` -> `Password sent; reading commandResult…`  (command write)
- `Password sent; reading commandResult…` -> `Login commandResult raw bytes: ...`  (device reply)
- `... raw bytes` -> `Login accepted, code=0x02`  (confirming re-login)
- whole op: `Rotating...` -> `Device password confirmed set to: ...`

- [ ] Rebuild + relaunch so debug_log records milliseconds
- [ ] Forget Device, capture the reset legs
- [ ] Re-pair, capture the rotate legs
- [ ] Repeat a few times for a spread, not one sample -- the point is `lower`/`upper`, not a centre
- [ ] Feed the result into `Latency.write` (currently 90-130ms, provisional) and add a dedicated
      `passwordSet` range if it turns out not to match a plain write
- [ ] Confirm `config.json` PIN still matches afterwards

### Follow-ups once the device is free

- [ ] Measure real per-operation distributions from `debug_log` now that it records milliseconds
      (landed in `f20ca37`), and replace the provisional centres *and* widths
- [ ] Particularly: per-record history streaming cost, which is currently the least certain figure
- [ ] `connect`, `enableNotifications`, `initializeSession` have no measurement at all -- nothing logs
      the start of a scan, so these may need a temporary timing log to pin down

## Where things live

- Mock: `Sources/TimeFlipApp/MockTimeFlipDevice.swift`
- Protocol it satisfies: `Sources/TimeFlipApp/TimeFlipEventSource.swift`
- Real device, for parity: `Sources/TimeFlipApp/TimeFlipBLEDevice.swift`
- Workflow tests that consume it: `Tests/TimeFlipAppTests/Workflows/` (see that folder's `README.md`)
