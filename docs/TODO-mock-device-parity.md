# TODO: mock device parity and realistic timing

Working checklist for making `MockTimeFlipDevice` behave like the real hardware: every function the
real device offers, and delays that vary the way a radio link does instead of returning instantly.

**This file is the handover.** Tick items as they land; anything unticked is where a resumed session
picks up. Design decisions already settled are recorded below so they don't get relitigated.

## Excluded, deliberately

- **Factory reset.** Not being modelled (owner's instruction, 2026-07-31). `factoryReset` also isn't on
  `TimeFlipSessionManaging` at all -- only on `TimeFlipBLEDevice` -- so modelling it means widening the
  protocol, not just adding a mock method. `Bench/02b` therefore stays a device-only checklist.
- **Measuring against the real device today.** The owner is using the cube to build up history. No
  reset, no full-history dump, no driving the app on their screen. Timing measurement waits.

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

### Timing mechanism

- [x] `DelayRange` with `lower`/`upper`, `.none`, `.fixed`, `.milliseconds`, `scaled(by:)`
- [x] `sample(using:)` drawing uniformly from a supplied generator
- [x] `Latency` converted from fixed `Duration`s to `DelayRange`s
- [x] `historyPerEntry` renamed `historyPerRecord`, sampled per record in `fetchHistory`
- [x] `waitForRadio` samples a range rather than sleeping a fixed span
- [ ] `SeededGenerator` + `delayGenerator` / `sampledDelays` stored properties (**build is red until
      this lands** -- `waitForRadio` already references both)
- [ ] `Configuration.randomSeed`, defaulting to something fixed so runs are reproducible by default
- [ ] Expose the drawn delays for assertions (`sampledDelays`, and a reset/clear helper)

### Functions the real device has and the mock doesn't

Delta taken from `TimeFlipBLEDevice`. Transport internals are **not** in scope -- `centralManager*`,
`peripheral`, `handleMainDisconnect`, `scheduleTimeout`, `cancelTimeout`, `hexString`, `withLock`,
`test` are CoreBluetooth plumbing, not device capabilities.

- [ ] `readDeviceTime() async -> Date?`
- [ ] `rotateDevicePassword() async -> String?`
- [ ] `resetDevicePasswordToDefault() async -> Bool` (password reset, *not* factory reset -- drop it if
      the owner reads "except the reset" as covering this too)
- [ ] `startDiscoveryScan(filterToTimeFlip: Bool) async`
- [ ] `stopDiscoveryScan()`
- [ ] `connectToDiscoveredDevice(id: UUID, password: String) async -> DeviceConnectOutcome`
- [ ] `cancelConnectionAttempt()`
- [ ] Discovery emits `onDeviceDiscovered`-equivalent results so the pairing flow can be exercised

### Tests

- [ ] Same seed produces the same delay sequence; different seeds differ
- [ ] Every sampled delay lies within its declared range
- [ ] A history fetch draws exactly one delay per record plus one for the command round trip
- [ ] Per-record delays are not all identical (the point of the range)
- [ ] `.instant` really is instant, and remains the default
- [ ] A workflow using the new discovery/pairing functions

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
