# Workflow tests

The CI counterpart of the on-device checklists in `Tests/Bench/` and `Tests/Interactive/`. Each
workflow drives a whole sequence through the real object graph (`AppDataStore`, `HistoryIngestor`,
`DailyFaceTotals`, `AppState`) with `MockTimeFlipDevice` in place of the hardware, then asserts what
landed in the database. They run on every push, in seconds, with no device and no human.

## Conventions

Deliberately close to `Tests/CLAUDE.md`'s rules for the scripted checklists, so the two read alike:

- **Numbered files, in the order they make sense to read.** Shared setup is `00-workflow-harness.swift`,
  mirroring `Tests/00-test-setup.md`. There is no point diagnosing a field value that never reached the
  device if the session was never established, so `W01` is the connection workflow.
- **Each workflow states its preconditions**, and step 1 establishes and asserts them rather than
  inheriting whatever ran before.
- **Steps are individual tests** inside a `@Suite(.serialized)`, which swift-testing runs in
  declaration order. XCTest's ordering is alphabetical and incidental, which is why these are
  swift-testing suites while the single-function tests stay XCTest.
- **A failed step stops the rest of that workflow.** Gating assertions are `try #require`, not
  `#expect` — `#expect` records and carries on, so a workflow built from `#expect` alone runs its
  remaining steps against state it was promised wouldn't exist.
- **Workflows never depend on each other.** Each gets its own database and its own mock device, so any
  one can be run alone, and the file numbering is for reading order, not execution coupling.

## What each workflow covers, and what it replaces

| Workflow | Covers | Replaces |
| --- | --- | --- |
| `W01-connection` | connect costs real radio time; wrong password rejected; nothing is reported until paired *and* logged in *and* notified | the connect/login preamble every bench checklist repeats |
| `W02-flips-while-disconnected` | flips while the app isn't listening are backfilled on reconnect, exactly once, in order, with one segment left open | `Interactive/01i` Scenario B (backlog after being out of range) |
| `W03-lock-blocks-flips` | a locked device refuses flips, nothing reaches the DB, the running segment is undisturbed, unlocking restores flips | the app's half of `Interactive/04i` Scenario A, and `Bench/04b` Scenario E's substance |
| `W04-history-resume` | the cheap skip path when nothing is new; a relaunch re-deriving its position from `device_event` without re-ingesting or skipping | `Bench/01b` Scenarios A and B |

## What cannot move to CI, and why

Worth being explicit, because "convert the tests to CI" has a hard ceiling here and the remaining
checklists are not simply un-migrated backlog:

- **No device.** CI has no TimeFlip. Anything asserting real firmware behaviour — that the cube itself
  refuses a flip while locked, that its event counter restarts low after a factory reset, that a real
  reconnect re-fetches — can only be demonstrated on hardware. The mock can assert the app's response
  to those situations, which is what the workflows above do; it cannot vouch for the device.
- **No Accessibility permission.** Every `System Events` step depends on TCC approval that cannot be
  granted non-interactively (see `Methods.md` Method 5), and screenshot steps additionally need Screen
  Recording. So the AppleScript-driven parts of `Bench/03b`–`07b` stay local.
- **UI that isn't reachable from a test.** The auto-pause stepper's press-and-hold (`Bench/05b`
  Scenarios C–E) and the LED field commits (`06b`) are AppKit gestures against a real window. Their
  *logic* is already unit-tested (`AutoPauseStepperTests`, `SettingsPersistenceTests`); the gesture
  itself is not CI material.
- **Genuinely visual, genuinely timed.** `Interactive/07i` Scenario B watches the menu bar flash over
  several seconds. `MenuBarStatusStyleTests` covers the colour *decision*; asserting the rendered
  pixels is feasible (proven separately) but needs the drawing helpers lifted out of
  `MenuBarController`, which is a source refactor, not a test change.
- **The live event path.** `for await event in device.events { handleDeviceEvent(event) }` and
  `handleDeviceEvent` are private inside `ApplicationDelegate`, tangled with the AppKit lifecycle. So a
  workflow drives history ingestion directly and cannot yet assert what the *live* stream does to the
  database. Extracting a `DeviceEventProcessor` would close that gap and is the single highest-value
  change for widening CI coverage.
- **`Bench/02b`, factory reset.** `factoryReset` isn't on `TimeFlipSessionManaging` at all — only on
  `TimeFlipBLEDevice` — so the mock cannot be asked to reset. Modelling it (no usable ack, device
  reboots, old password briefly still accepted, ends never-paired) would make a good workflow, but it
  means adding behaviour, not just a test.

## Adding a workflow

Number it after the last one, take the harness via `WorkflowHarness.shared("<id>")`, open every step
after the first with `try harness.requirePreviousStepsPassed()`, and wrap each step's body in
`harness.step("<name>") { ... }` so a failure is attributed to the step that caused it. Add a row to
the table above, and say in the doc comment what the workflow does *not* cover — that line is what
stops a green CI run being mistaken for hardware coverage.
