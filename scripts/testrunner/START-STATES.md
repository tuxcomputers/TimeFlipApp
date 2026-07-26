# Reaching the test start conditions from any current state

Before a run can begin, the machine/app/device can be in many different states -- on either
database, app up or down, device paired or not, timing or paused. This document defines the
**target** (the start test conditions) once, lists the **dimensions** a current state varies over,
then gives one labeled section per reachable current state with the numbered steps that funnel it
to the target. Sections chain (a step can say "go to **section**"), so every combination has a
path.

How each thing is detected (the exact `sqlite3` queries / helpers) lives in
[DETECTION.md](DETECTION.md); this document is the *flow*, not the detection mechanics.

> **Implementation.** This flow is implemented by `00-test-setup.md` plus the
> `ensure_not_timing_on_production` pre-flight:
> - The **early** timing gate (pre-flight) only fires when the app is already running -- with it
>   shut down the last `device_event` on disk is stale (a dev could have double-tapped to pause or
>   changed faces since), so it defers.
> - `00-test-setup.md` Step 4 restarts (or, when the app was down, just starts) it, Steps 5--6 wait
>   for reconnect + history sync, and **Step 7 re-checks the timing gate on that fresh data** before
>   any destructive step. Step 7 runs whenever history is being recorded, so it also covers switching
>   onto production mid-run (the "choose → y" path).
> - The reconnect waits (Steps 5, 9) prompt the dev to pair / power on the device and keep waiting,
>   rather than failing opaquely (**Device not paired**).
> - Step 10 (`ensure_unlocked_unpaused`) leaves the device unlocked + unpaused for every run.

---

## Start test conditions (the destination)

Every path below ends here:

- **DB:** on **test** -- `db_type = {"type":"test"}`, freshly rebuilt this run (except on a
  restart-from-scenario resume, which preserves the existing `test.sqlite` -- see below).
- **App:** **running**; device **paired + connected** (a recent `Login accepted`); history **synced**.
- **Device:** **unlocked** and **unpaused**.
- **Production history:** **recorded** to `production.sqlite` before the switch to test -- unless the
  dev explicitly opted out when the run started off-production.
- **Device event number:** **≥ 10** events -- but *only when the run includes a history-refresh
  checklist* (01b/01i); the setup builds it then, and skips it otherwise. (02b separately needs a
  pre-reset baseline **N > 0**, which any history satisfies.)

Environment prerequisites -- not gates the runner queries, but a run can't succeed without them
(their absence surfaces as a later failure):

- **Developer Mode enabled** and the `debug` setting's `enabled = true` -- else nothing is written
  to `debug_log`, which is the entire detection channel.
- **App built** at `.build/bundler/apps/TimeFlip/TimeFlip.app/Contents/MacOS/TimeFlip`.
- **`production.sqlite` exists** -- `use-production-database.sh` refuses to relink to a missing file.
- **Device-manipulation warning acknowledged** (unless `--yes`).
- **Run order:** the whole Bench suite before any Interactive checklist.

---

## Current-state dimensions

A current state is a combination of:

- **DB:** `production` | `test` -- readable from the DB file at any time, app up or down.
- **App:** `running` | `not running` -- `pgrep`.
- **Device paired:** `paired` | `not paired` -- the app writes its own `paired` setting (on startup
  and every pair / reconnect / factory-reset / disconnect), so this is directly queryable, not
  inferred. Distinct from *connected*: a paired device can be off / out of range.
- **Pause:** `timing` | `paused` -- only *trustworthy* after the app has connected and synced
  history; a DB left by a shut-down app may not reflect a since-shutdown double-tap or face change.
- **Locked:** `locked` | `unlocked` -- resolved by the final unlock/unpause step, not a branch.
- **Device event number** -- built to ≥ 10 by the setup's final step, but only when the run includes
  a history-refresh checklist (01b/01i); otherwise not a condition for that run.

Because the device dimensions aren't observable until the app is up and synced, the states funnel:
an app that's down is started and synced first, *then* its device state is read and branched on.

---

## Prod and app not running

- Prod DB
- App not running
- Device timing/paused **unknown** (could have been paused/flipped/double-tapped since shutdown)

1. Start the app.
2. Wait for device connection (a fresh `Login accepted`). If none appears within the timeout, go to
   **Device not paired**.
3. Wait for history to sync (`history fetch complete: trigger=startup`) -- only now does the latest
   `device_event` reflect the physical device.
4. Read the latest event's `is_paused`:
   - timing → go to **Prod and device is timing**
   - paused → go to **Prod and device is paused**

## Prod and device is timing

- Prod DB
- App running, device paired + synced
- Device timing (latest event is not paused -- a real activity is running)

1. Exit with a message: a real activity is timing; the run switches to test and factory-resets the
   device at the end, which would interfere. Pause the device, then re-run.

## Prod and device is paused

- Prod DB
- App running, device paired + synced
- Device paused

1. Record production history: capture the baseline max `debug_log_id`, restart the app, wait for the
   reconnect, then wait for `history fetch complete: trigger=startup` -- so all real device history
   is on `production.sqlite` before we leave it.
2. Go to **Switch to test and finalise**.

## Prod and device not paired

- Prod DB
- App running
- No connection (device not paired / powered off / out of range)

1. Go to **Device not paired**.

## Not on production and app not running

- Test DB (or any non-production)
- App not running

1. Start the app.
2. Wait for device connection. If none within the timeout, go to **Device not paired**.
3. Go to **Not on production — choose**.

## Not on production and app running

- Test DB (or any non-production)
- App running, device paired
- Timing/paused **irrelevant** here -- on a non-production DB the latest event is a test artifact,
  not a real activity to protect.

1. Go to **Not on production — choose**.

## Not on production — choose

- DB not production, app running, device paired + connected

1. Ask the dev: switch to production and record its history first? (`y`/`n`)
   - **y** → switch to production (`use-production-database.sh` relinks the symlink), then go to
     **Prod and app not running** step 1 (restart on prod, wait for connect + sync, then branch on
     timing/paused). Note: if the device turns out to be *timing* on production, this re-enters
     **Prod and device is timing** and the run aborts -- recording history can't proceed while a
     real activity would be interrupted by the end-of-run reset.
   - **n** → go to **Switch to test and finalise** (skip recording; the test DB is rebuilt anyway).

## Device not paired

- App running
- No `Login accepted` within the connection timeout (not paired / powered off / out of range)

1. Ask the dev to pair the device (Scan → pair), or power it on / bring it in range.
2. Once a `Login accepted` appears, resume the DB-appropriate section:
   - on production → **Prod and app not running** step 3 (wait for sync, then branch)
   - not on production → **Not on production — choose**

## Switch to test and finalise

The shared terminal path -- every non-aborting branch ends here.

- App running, device paired + connected; production history recorded (or the dev opted out)

1. Quit the app, run `use-test-database.sh $db_mode` (fresh run: creates a fresh empty
   `test.sqlite`; restart-from-scenario resume passes `keep`, preserving the existing `test.sqlite`
   so state earlier scenarios built survives), repoint the `appdata.sqlite` symlink at it, relaunch.
   On a resume the production-history recording above is also skipped (we stay on test throughout).
2. Read the app's `paired` setting. If it isn't paired -- the **"test DB + not paired"** start
   state that a prior run's end-of-run cleanup reset leaves behind (pairing is device-level, and the
   reset forgets the device) -- **script the pair**: Scan for Devices, coordinate-click the
   discovered row (`cgevent_click_element`), wait for the pairing-complete marker. Skipped when
   already paired (it auto-reconnects, since pairing lives in UserDefaults and survives the switch).
3. Confirm the device is connected against the fresh test database (`Login accepted`).
4. Unlock, then unpause the device (`ensure_unlocked_unpaused`) so scenarios start from a clean
   unlocked, unpaused state.
5. Confirm `db_type` now reads `{"type":"test"}`.
6. If this run includes a history-refresh checklist (01b/01i), ensure **≥ 10** device events:
   already-≥10 passes instantly, otherwise prompt the dev to flip the device and wait until the
   count reaches 10 (leaving it resting on one face). Skipped for runs that don't need history.
7. **Start test conditions reached.**

> The `paired` read in step 2 is the app's own `paired` setting (written on startup and on every
> pair / reconnect / factory-reset / disconnect), not a heuristic -- so "is it paired" is a
> definitive gate, and the connectivity confirm (step 3) only runs once paired. See
> `00-test-setup.md` and DETECTION.md.
