# Project Conventions

## Requests that affect real device behavior

- Before implementing a request that changes how the physical TimeFlip device behaves (e.g.
  "set auto-pause to 10 seconds"), check it against what the device's BLE protocol actually
  supports (see `docs/TimeFlip2 BLE Protocol v4.3.md`/`docs/timeflip.md`) -- granularity,
  ranges, whether a value has any read-back, etc.
- If the request isn't achievable as literally stated (e.g. the device only supports whole-minute
  auto-pause delays, so "10 seconds" can't make it fire in 10 seconds), say so explicitly and
  explain the actual constraint before implementing anything -- don't silently build something
  that looks like it does what was asked but can't actually behave that way on real hardware.

## Running the device tests

- When the user asks to "run the device tests" (or to run the bench/interactive checklists), read
  `Tests/CLAUDE.md` first and follow it. It defines the procedure: run the **Bench** suite (the
  script-drivable on-device checklists) first, then the **Interactive** suite (the ones needing a
  person).
- These on-device checklists under `Tests/Bench/` and `Tests/Interactive/` are separate from
  `swift test` (the hermetic unit suite) -- "run the device tests" means the checklists, not
  `swift test`.

## Running the app interactively for visual verification (screenshots, driving the UI)

- This launches a real window on the user's actual screen -- it is not an isolated/headless
  sandbox. Keystrokes and clicks the user makes while the app has focus can land in it (this has
  actually happened -- see git history around the Settings-window sizing fix).
- Before launching the app for this purpose, post a clear, prominent, impossible-to-miss message
  asking the user to acknowledge and to avoid touching the keyboard/mouse until told the
  verification is finished. Wait for that acknowledgment before launching.
- Once done (or if interrupted), immediately kill the launched process, revert any temporary
  debug-only scaffolding added purely to drive the verification (e.g. an env-var-gated hook to
  jump straight to a window/tab) -- these must never ship as part of the actual change -- and post
  an equally big, equally prominent message telling the user it's safe to use the keyboard/mouse
  again. The "all clear" matters as much as the initial warning -- don't let it shrink to a small
  aside in a longer message.

## TimeFlip2 BLE protocol documentation

- `docs/TimeFlip2 BLE Protocol v4.3.md` is the official vendor protocol spec and takes priority
  over `docs/timeflip.md` (a developer-written summary of this codebase's BLE driver) whenever
  the two disagree.
- If the official spec doesn't cover something, fall back to `docs/timeflip.md`.

## Debug print messages

- All dev-only `print(...)` console messages (gated on `DeveloperMode.isEnabled`) must lead with
  a zero-padded 24-hour local time, followed by the `[Tag]` naming the action/source, e.g.:
  ```
  13:25:38 [TimeFlip ] Login accepted, code=0x02
  13:25:39 [dev-check] device_event max_event_number OK: in_memory=112 db=112
  ```
- Use `DeveloperMode.debugPrint(_ tag: DebugTag, _:)` (in `DeveloperConfigStore.swift`) rather than
  a bare `print(...)` call — it prepends the timestamp and gates on `isEnabled` itself, so call
  sites don't need their own `if DeveloperMode.isEnabled { ... }` wrapper.
- The tag names all pad to the same bracket width (right-padded with spaces) so console lines stay
  aligned, per the example above. This is enforced by `DeveloperMode.DebugTag`: its cases hold the
  tag names, and `width` is derived from the longest case's name, so adding a case automatically
  re-pads every tag — **when a new debug message is requested, add its tag as a new `DebugTag`
  case instead of inlining a `[Tag]` string in the message**, and double check the console output
  afterwards to confirm every tag still lines up (a new case that's longer than all existing ones
  widens every other tag's padding too).
