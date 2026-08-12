# TODO: mock device parity and realistic timing

Working checklist for making `MockTimeFlipDevice` behave like the real hardware: every function the real device offers, and delays that vary the way a radio link does instead of returning instantly.

**This file is the handover.** Tick items as they land; anything unticked is where a resumed session picks up. Design decisions already settled are recorded below so they don't get relitigated.

## Excluded, deliberately

- ~~**Factory reset.**~~ **Now modelled** (2026-07-31). The protocol was widened as anticipated: `factoryReset` is on `TimeFlipSessionManaging`, and `ApplicationDelegate` calls it through the protocol instead of casting to `TimeFlipBLEDevice`, which is what had made the path unreachable for the mock. Covered by `Workflows/W06-factory-reset.swift`. The reconnect/confirm loop around it stays out of scope -- it's private AppKit-lifecycle code.

**No longer excluded:** the owner released the device on 2026-07-31 ("feel free to use it to check timings of reset etc") and is building the event history up deliberately to give the per-record figure a real sample. The earlier "no reset, no full-history dump" restriction is lifted.

## Settled design decisions

1. **Ranges, not fixed delays.** `DelayRange { lower, upper }`, sampled uniformly per call. A run of history records comes back e.g. 184ms, 198ms, 163ms rather than the same figure repeatedly, which is both what the device does and what stops a caller depending on a constant.
2. **Per record, not per fetch.** History charges one draw *per record* on top of a fixed command-round-trip cost, so a fifty-record backlog is fifty independent delays.
3. **Seeded randomness.** A `SeededGenerator` on the mock, seed settable via `Configuration`. Random delays must not make a failure unreproducible: same seed, same sequence, replayable failure.
4. **`.instant` stays the default.** Every existing test and the app itself are unaffected unless they opt in to `.realistic()`.
5. **Latency charged before the guards.** A rejected command still costs a round trip on real hardware, so the caller waits either way.
6. ~~**Spreads are provisional.**~~ **Superseded 2026-07-31**: every figure is now measured directly against a millisecond `debug_log`, min-to-max rather than assumed +/-20%. The old straddle-counting estimate turned out to be wrong by ~3x on the phases that dominate. See the measured table below.
7. **History frames are quantised, not smoothly distributed.** Gaps land on whole multiples of the BLE connection interval, so `historyFrames` is a `FrameCadence`, not a `DelayRange`. A uniform range cannot produce the observed bursts.
8. **Fresh links cost about twice settled ones.** Hence `settledWrite` alongside `write`; it is a property of the connection, not of any command.

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
- [x] Expose the drawn delays for assertions via `sampledDelays`, plus `clearSampledDelays()` for measuring one phase of a session in isolation (added once the password tests needed it)

### Functions the real device has and the mock doesn't

Delta taken from `TimeFlipBLEDevice`. Transport internals are **not** in scope -- `centralManager*`, `peripheral`, `handleMainDisconnect`, `scheduleTimeout`, `cancelTimeout`, `hexString`, `withLock`, `test` are CoreBluetooth plumbing, not device capabilities.

- [x] `readDeviceTime() async -> Date?`
- [x] `rotateDevicePassword() async -> String?`
- [x] `resetDevicePasswordToDefault() async -> Bool` (password reset, *not* factory reset -- history and pairing untouched, asserted by a test. Say if "except the reset" was meant to cover this.)
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
- [x] Frame gaps quantise to whole connection intervals, and the modelled mean matches the measured 19.4ms
- [x] Both password operations charge two legs, and a settled-session reset is not billed at fresh-link rates
- [x] A factory-reset workflow (`Workflows/W06-factory-reset.swift`) plus unit coverage of the reboot window expiring on its own

### Instrumentation added so the measurement is possible at all (2026-07-31)

Commits `fdf51e2`, `69c6266`. Three operations had no measurable duration before this, which is why they were listed as unmeasured rather than merely imprecise:

- `connect` / `enableNotifications` / `initializeSession` logged only to `os_log`, never to `debug_log`. Now bracketed by the `conn-phase` tag, with `connect` split into radio-power, scan+link and characteristic discovery so a slow connect can be attributed.
- `resetDevicePasswordToDefault` and `factoryReset` logged only their *completion*, with no start marker anywhere. Both now log a start, and all three password/reset operations self-report their 0x30/0xFF write and their confirming re-login separately.
- History frames had no per-frame timing. The `hist-time` tag reports the command round trip and every inter-frame gap, accumulated in memory and emitted as one row -- a row per frame would insert into SQLite inside the gap being measured.

Spans use `ContinuousClock`, not `Date`: a wall-clock adjustment mid-connect would corrupt them.

Extraction script (scratchpad, promote to `scripts/` if it earns its keep): `measure_timings.py [db] [--since ISO8601]`, which reports n/min/p50/max/mean per leg and suggests a 5th-95th-percentile `DelayRange`. It warns loudly if the DB predates `f20ca37` and has no milliseconds, since every figure would silently quantise to whole seconds.

### Measured, and folded into the mock (2026-07-31, commit `5e29916`)

Nine connect/login sequences and five full 21-record history dumps on the owner's device. Every `Latency` figure is now observed rather than inferred; the old ones came from second-resolution straddle counting, which gives a centre and no spread.

| Leg | Was (assumed) | Measured | n |
| --- | --- | --- | --- |
| `connect` | 600-1000ms | **2232-4550ms** | 9 |
| `enableNotifications` | 120-180ms | **595-715ms** | 9 |
| `initializeSession` | 200-300ms | **1137-1289ms** | 9 |
| `login` | 210-310ms | 239-270ms | 9 |
| `write` | 90-130ms | 115-152ms | 9 |
| `read` | 105-155ms | 53-79ms | 117 |
| `historyRead` | 105-155ms | 30-240ms (bimodal) | 25 |

Bringing a session up costs **~4 seconds**, not the ~1 the mock modelled. Within `connect`, the variance is almost all in scan+link (1182-3306ms); characteristic discovery is steady (1047-1197ms) and waiting for the radio to power up is negligible (0-46ms).

`historyRead` is genuinely bimodal, not merely wide: issued right after connect it returns in 30-45ms, mid-session in 155-240ms. Modelled as the full span, since the mock has no notion of session age.

**The shape correction matters more than the numbers.** History frames do not arrive independently: they land on BLE connection events, so gaps quantise to whole multiples of a ~14.5ms interval (residual stdev 1.32ms over 105 gaps), distributed

| intervals | share | observed |
| --- | --- | --- |
| 0 (two frames, one connection event) | 3.8% | 0-1ms |
| 1 | 62.9% | 12-18ms |
| 2 | 29.5% | 27-31ms |
| 3 | 3.8% | 41-45ms |

Mean 19.4ms per record, which held at 19 in all five runs. `historyPerRecord: DelayRange` is therefore replaced by `historyFrames: FrameCadence`. A uniform range cannot generate a burst.

Cross-check that the legs are self-consistent: `lock` is a write plus a read-back, measured 173-224ms (p50 186), against `write` p50 118 + `read` p50 62 = 180.

- [x] Measure real per-operation distributions and replace the provisional centres *and* widths
- [x] Per-record history streaming cost, previously the least certain figure
- [x] `connect`, `enableNotifications`, `initializeSession`, which had no measurement at all

Method, if it needs repeating: the ingest position is derived from `device_event`, not stored in a cursor table (see `AppDataStore.swift:1438`), so clearing that table makes the next launch re-fetch from event 0. That gives repeatable full dumps without touching the device. Scripts are in the session scratchpad (`full_history_cycle.sh`, `analyse_frames.py`, `measure_timings.py`).

### Still to measure: password and reset timing (needs the owner hands-off)

Owner asked for this specifically, flipping between the factory default and the dev PIN. Both values are known (`000000` / `123456`), so a half-completed rotation can only leave the cube on one of two PINs -- owner has said they'll try each if `config.json` ends up wrong, so there's no lock-out risk.

The two operations are triggered only from the UI, so this needs the app driven with the owner hands-off (root `CLAUDE.md`'s live-interaction ritual):

- **Forget Device** -> `resetDevicePasswordToDefault()` -> device back to `000000` (**historic**: Forget stopped doing this on 2026-08-11 -- it is local now and touches no PIN, see `AppState.forgetDevice`. The timings below were measured through it while it did, and `resetDevicePasswordToDefault()` itself is unchanged and still parity-tested; nothing in the app calls it any more.)
- **Scan, tap the device, pair** -> `rotateDevicePassword()` -> device to `123456` (rotation runs *only* in the pairing flow -- `ApplicationDelegate:708`, `skipConnect` -- routine reconnects reuse the stored password, so a plain restart will not exercise it)

Both operations now self-report their legs (commit `69c6266`), split into the 0x30 write and the confirming re-login, so the extraction is just a matter of running them a few times.

- [x] Rebuild + relaunch so `debug_log` records milliseconds
- [x] Forget Device, capture the reset legs
- [x] Re-pair, capture the rotate legs
- [x] Repeat a few times for a spread, not one sample -- seven pairings, n=6 per leg
- [x] Add a dedicated `passwordSet` range if it turns out not to match a plain `write` -- **not needed**, see below
- [x] Confirm `config.json` PIN still matches afterwards -- `123456`, checked against the device's last accepted login rather than assumed

| Leg | rotate (n=6) | reset (n=6) |
| --- | --- | --- |
| 0x30 write | 113-144ms | 54-79ms |
| confirm re-login | 120-123ms | 60-61ms |
| **total** | **236-266ms** | **116-141ms** |

No `passwordSet` range: the rotation's write (113-144ms) matches a plain `write` (115-152ms). The reset being half that is **the link, not the command** -- rotation only ever runs inside the pairing flow on a freshly connected probe, the reset on a settled session. The same 2x split appears in the confirm re-logins (120-123 vs 60-61) and in login overall (245ms at connect vs 59ms established), so it is a transport property, modelled as `Latency.settledWrite` alongside `write`.

Both operations now charge **two** legs in the mock (write plus confirming re-login). They previously charged one write and then a full connect-time `login`, overstating a rotation as 354-422ms and a reset far worse.

### Factory reset, measured 2026-07-31

```
0xFF write:                  78ms
0xFF sent -> confirmed:  13,544ms
```

The write is trivial; the cost is the erase-and-reboot. It also reproduced the race the driver's comments describe: **two seconds after the reset the cube still accepted the old PIN**, and only on the second reconnect was `123456` rejected and `000000` accepted. Live confirmation that refusing to treat an immediate re-login as proof is load-bearing, not defensive coding.

Now modelled, using exactly these numbers: `Latency.factoryResetReboot` is the 13,544ms window, and the mock keeps honouring the pre-reset password for its duration while refusing the default. The 0xFF write is charged as a `settledWrite` (Forget/Reset run on a settled session), close to the 78ms measured.

Two details the modelling forced out that weren't obvious from the measurement alone:

- The counter must restart at **1, not 0**. `streamHistory` treats event number 0 as the end-of-stream sentinel, so a device allocating 0 would terminate its own history stream on its first record. The hardware was observed going nil -> 1 -> 2, agreeing.
- A rebooted cube is still lying on a face, so it **starts a new segment immediately** -- but that segment isn't an *event* until a flip closes it. That's the source of the familiar post-reset "idle, frozen duration" display: correct behaviour, not a bug.

**Factory reset**, also owner-approved on 2026-07-31 ("the events are not work records"), and it **erases the device's event history** -- so it must run after every history measurement, which is why it is last here. `factory reset 0xFF write` covers only sending the command; the cost that matters is the erase-and-reboot, observable as the gap from `Factory reset (0xFF) sent` to the device reappearing on the default password.

- [ ] Capture the 0xFF write and the reboot-to-default-login gap
- [ ] Re-pair afterwards so the cube isn't left unpaired on `000000`

### The full spec command set (2026-07-31)

Parity had been measured against `TimeFlipBLEDevice`, so it could only ever find things the *driver* had and the mock didn't. Checked against `docs/TimeFlip2 BLE Protocol v4.3.md` instead, four commands turned out to be missing from **both**: `0x13` set face task params, `0x14` read them, `0x15` set device name, `0xFE` reset task info. All four are now implemented in the driver and the mock, so every command in the spec is covered.

All four verified working on real hardware, with read-backs proving they take effect rather than being accepted and discarded:

| Command | Measured | n | Result |
| --- | --- | --- | --- |
| `0x14` read face task | 116-151ms | 5 | returns mode/limit/elapsed |
| `0x13` write face task | 118-119ms | 5 | read-back showed `mode=1 limit=1500` |
| `0x15` set device name | 58-118ms | 6 | name changed, then restored |
| `0xFE` reset task info | 58-89ms | 3 | read-back showed `mode=0 limit=0` |

**None needs its own `DelayRange`** -- each is an ordinary command round trip, priced by link age.

**This probe corrected a mistake in the existing figures.** `read` (53-79ms) and `write` (115-152ms) looked like a read/write difference, but `read` was sampled mid-session and `write` during pairing, so the two differ in *when* they ran as much as what they did -- and `read` is within noise of `settledWrite` (54-79ms). These commands ran as one sequence that crossed the boundary, separating the effects: a read-shaped command (`0x14`) on a fresh link cost 116-151ms and a write-shaped one (`0xFE`) on a settled link cost 58-89ms, the opposite of what an intrinsic read/write difference predicts. Command direction doesn't matter; connection age does. `read` and `settledWrite` are very likely the same quantity measured twice.

- [ ] Consider merging `read` into `settledWrite`; needs re-deciding what each existing caller charges
- [x] The driver had no idea what the cube was actually called: the stored name held `"TimeFlip"` (a literal in `ApplicationDelegate`) while the cube advertised `"TimeFlip v2.0"`. *Done — `TimeFlipDevice.deviceName` exposes it, via `CBPeripheral.name`, which on Apple platforms is the platform's own reading of `0x2A00`; the Generic Access service `0x1800` is never exposed to apps, so there is no characteristic to discover.* The mock implements it too, so parity holds.

**Tests for these four are written but commented out** in `MockDeviceParityTests.swift`: the app has no task/pomodoro or device-name feature, so asserting behaviour now would pin down decisions nobody has made. Kept rather than deleted because the wire formats were derived from the spec and re-deriving them is wasted work. They compile as written.

Measured via temporary env-var-gated scaffolding in `ApplicationDelegate` (`CLAUDE.md`'s sanctioned pattern), **since reverted** -- `swift test` is hermetic and has no Bluetooth permission, so a test could not have reached the cube.

## Where things live

- Mock: `Sources/TimeFlipApp/MockTimeFlipDevice.swift`
- Protocol it satisfies: `Sources/TimeFlipApp/TimeFlipEventSource.swift`
- Real device, for parity: `Sources/TimeFlipApp/TimeFlipBLEDevice.swift`
- Workflow tests that consume it: `Tests/TimeFlipAppTests/Workflows/` (see that folder's `README.md`)
