# Automation methods

The concrete, verified "how" behind every automated step in `Tests/Bench/`/`Tests/Interactive/`.
Each method below is self-contained and independently linkable -- a checklist step that needs one
says so explicitly (`Method: <name>`) instead of re-describing the mechanics inline. Two steps
needing the same technique both point here rather than duplicating text; a step needing a different
technique updates its own reference. Discovering a new technique means adding a new method here and
linking it from the step that needed it -- same "verified against a real, live run" bar as
`CLAUDE.md`.

`CLAUDE.md` still holds the rules, process, and background facts about app/device behavior; this
file holds only reusable step-execution techniques.

## Build the app

`scripts/run.sh` builds+launches in one step, blocking -- background it, poll the log for
`"Build of product"`/`"error:"`. Bundle:
`.build/bundler/apps/TimeFlip/TimeFlip.app/Contents/MacOS/TimeFlip`.

## Launch the app for a Claude-driven step

Invoke the built binary directly (inherits the shell's env vars, needed for debug hooks) --
`scripts/run.sh` doesn't reliably pass them through.

## Quit the app

`osascript -e 'tell application "TimeFlip" to quit'`. Never `pkill`/`kill` for a real test step --
skips `applicationWillTerminate` (e.g. `pause_on_lock`-on-quit never fires). `pkill` is fine only as
last-resort cleanup.

## Confirm device reconnect

Query `debug_log` for a fresh `TimeFlip`-tagged `"Login accepted, code=0x02"` row -- don't ask the
user.
```
sqlite3 ~/Library/Application\ Support/TimeFlip/appdata.sqlite \
  "SELECT logged_at, message FROM debug_log WHERE tag='TimeFlip' AND message LIKE 'Login accepted%' ORDER BY debug_log_id DESC LIMIT 1;"
```

## Grant/verify Accessibility permission

Accessibility (separate from Screen Recording) must be granted to the calling app -- trace it via
`ps -o ppid=,comm= -p <pid>` up from the current shell, under System Settings -> Privacy & Security
-> Accessibility, then fully quit/reopen that app. Canary (a *real* result, not a `-1719` error,
confirms it works):
```
osascript -e 'tell application "System Events" to tell process "Finder" to get name of every menu bar item of menu bar 1'
```

## Click a status-item menu item

Open and click the target item in the *same* `tell` block:
```applescript
tell application "System Events"
    tell process "TimeFlip"
        tell menu bar item 1 of menu bar 2
            click
            delay 0.5
            click menu item "Unlock" of menu 1
        end tell
    end tell
end tell
```
Read names first (`name of every menu item of menu 1`) to check current state. `key code 53`
dismisses (Escape), same block. **Never split read and click across two `osascript` calls** -- the
menu stays open and the next call collides and hangs (~2 min stall, easily misread as an
Accessibility problem; a real permission denial errors instantly with `-1719`, it doesn't hang).

## Simulate a real click, double-click, or held press via CGEventPost

AppleScript's `click`/`click at {x, y}` (System Events) never reaches genuine screen-position-based
gestures -- confirmed dead ends for the status item's click-right-half toggle and the auto-pause
stepper arrows' held press: both are raw `NSEvent`-driven hit-tests, not menu/AX actions, and
synthetic AX/coordinate clicks simply never arrive (no effect, and -- once the `click`-tagged debug
print existed to check -- no log line either).

A raw `CGEventPost` (e.g. via Python's `pyobjc`/`Quartz`) *does* arrive correctly, but only if
`kCGMouseEventClickState` is set explicitly on both the down and up events -- omitting it makes
macOS treat every event as a fresh single click (`clickCount` always `1`), which is the actual root
cause behind "synthetic double-clicks don't work" (not click speed, a missing metadata field):

```python
import Quartz, time
X, Y = <screen point x>, <screen point y>
def post(kind, click_state):
    e = Quartz.CGEventCreateMouseEvent(None, kind, (X, Y), Quartz.kCGMouseButtonLeft)
    Quartz.CGEventSetIntegerValueField(e, Quartz.kCGMouseEventClickState, click_state)
    Quartz.CGEventPost(Quartz.kCGHIDEventTap, e)

# Double-click (click_state=2 on the second down/up pair, within the system double-click interval):
post(Quartz.kCGEventLeftMouseDown, 1); post(Quartz.kCGEventLeftMouseUp, 1)
time.sleep(0.15)
post(Quartz.kCGEventLeftMouseDown, 2); post(Quartz.kCGEventLeftMouseUp, 2)

# Held press (mouseDown, wait, mouseUp -- same click_state=1 throughout):
post(Quartz.kCGEventLeftMouseDown, 1)
time.sleep(4)  # however long the hold needs to run
post(Quartz.kCGEventLeftMouseUp, 1)
```

Confirmed live: this genuinely locked/unlocked the device via the status item's double-click
gesture (`debug_log` showed `clickCount=1` then `clickCount=2`, then `"Lock ON triggered"`), and a
plain single click (`click_state=1`, no second pair) genuinely toggled pause/resume the same way
(`debug_log` `side=right clickCount=1`, a fresh `device_event` row with `is_paused` flipped) -- both
previously believed impossible to script (see the now-superseded notes this replaced, still visible
in git history).

Also confirmed live for the auto-pause stepper: a single held `mouseDown`/wait/`mouseUp` pair ran
the full documented deceleration curve correctly in **both** directions -- a 4-second hold on the
down arrow (`26 -> 25...20 -> 15, 10, 5, 0`, stopping cleanly at 0) and a 4-second hold on the up
arrow (`51 -> 52...60 -> 65, 70...100`, single steps to the next 10-gridline then by-5) -- and a
plain quick click (no hold at all) also genuinely incremented the value by 1, superseding the older
belief that this control needed a real click.

Also confirmed for the compound "hold interrupted by closing the window" gesture (previously assumed
to need two real hands): `mouseDown` on the arrow, wait ~1s, post a synthetic `Escape` keydown/keyup
(`CGEventCreateKeyboardEvent(None, 53, True/False)`) while the mouse is still conceptually "down" (no
`mouseUp` posted yet), wait, then `mouseUp` -- the window closed on the synthetic Escape exactly as
it does on a real one, the value stopped advancing at that instant and stayed put (checked
immediately and 5s later), and reopening the window and clicking once afterward still incremented by
exactly 1 -- the control wasn't left in a stuck "held" state. Two independent synthetic event streams
(mouse and keyboard) interleave exactly like two real hands would; nothing about the gesture actually
required physical simultaneity, just event ordering.

Get target coordinates from the element's `position`/`size` via accessibility (Read a label or value
via accessibility, below) -- already in points, no pixel conversion needed. Caveat: this failed for
the auto-pause stepper's own two `image` elements specifically -- both reported identical
`position`/`size` (a SwiftUI AX quirk collapsing custom-drawn glyphs to their container's frame, not
their own) -- so for that control, derive the coordinates instead from the adjacent text field's
reliable `position`/`size` (real `AXTextField`) plus a `screencapture -R` crop to visually place the
arrows relative to it (pixel-based, 2x retina -- halve to convert back to point space).

## Status-item click gesture

The status item's own click-right-half gesture (single-click pause/resume toggle, double-click lock
toggle) is a raw screen-position hit-test (`MenuBarController.swift`), not a menu action. Drive it
with the CGEventPost technique above, at the status item's own `position`/`size` (right half: `x =
position.x + size.width * 0.75`, `y = position.y + size.height / 2` roughly) -- confirmed live for
both the single-click pause/resume toggle and the double-click lock toggle. `handleStatusItemClick`
also logs every real click it receives (`debug_log` tag `click`, `"Status item clicked:
side=left/right clickCount=N"`), useful to confirm a click (synthetic or real) actually landed.

## Discovered-device row click

The discovered-device row in the pairing list (Device tab -> TimeFlip section) is a plain
`Text`+`.onTapGesture`, not a `Button` -- neither an AX `click` nor `click at {x, y}` triggers it
(confirmed live, zero effect either way). Same capability class as the status-item gesture above, so
the CGEventPost technique likely also drives it, though not yet re-confirmed live with this specific
control. Where this can't be deferred to an Interactive checklist (e.g.
`Bench/02b-reset-device-checklist.md` must end with the device paired for `03b`-`07b` to run), ask
the user ad hoc instead of a formal `(You)` step -- see "Running a checklist" rule 3 in `CLAUDE.md`
-- unless the CGEventPost technique is confirmed for it too, in which case it becomes a normal
`(Claude)` step.

## Switch Settings-window tabs

`click radio button <N> of radio group 1 of group 1 of toolbar 1 of window "TimeFlip Settings"`
(1/2/3 = Device/Facets/Report). A radio button's `title` is always `missing value` -- use
`description`.

## Read a label or value via accessibility

Read any label/value via accessibility (`static text`/control `value`) -- no screenshot needed. Dump
`entire contents` of the window to find an element's path; re-derive each time, since indices shift
with which disclosures are expanded.

## Edit a text field

Focus it, `cmd+A`, type the value -- it commits live on every keystroke; `keystroke tab` is optional
and only moves focus (a `tab` between rapid edits on the same field misdirects the next value
elsewhere, so omit it for back-to-back edits). `keystroke` always targets the frontmost app
regardless of which process the `tell` addresses -- run `tell application "TimeFlip" to activate`
before every sequence and confirm with `name of first process whose frontmost is true`. A plain
`click` on a field doesn't reliably set focus either -- follow with `set focused of e to true` and
confirm it reads `true`, all in one `osascript` call (a stale element reference doesn't survive
across calls).

## Click a button, checkbox, or slider

`click button "..."` / `set value of checkbox ... to true` -- confirm each via `debug_log`/DB the
first time it's actually used.

## Auto-pause stepper arrows

The auto-pause field's up/down stepper arrows are custom `Image`+`onLongPressGesture` views, not
real controls -- AX/coordinate clicks via AppleScript don't move them, but the CGEventPost technique
above (see the coordinate caveat there) does: confirmed live for a plain click, a held press (both
directions, full deceleration curve), and the hold-interrupted-by-window-close compound gesture.

## Expand or collapse a disclosure group

A `DisclosureGroup` shows as role `AXDisclosureTriangle` ("UI element", no readable label) --
identify it by position among siblings, `click` to expand/collapse.

## Confirm a confirmation-dialog sheet

A `.confirmationDialog` opens as `sheet 1 of window ...`, not a button on the window itself --
address it that way; its buttons' `title` is also `missing value`, use `description` to tell them
apart (e.g. `Cancel` vs. the destructive confirm).

## Screenshot-based visual confirmation

For a **static**, non-accessibility-readable state, a `(Claude)` screenshot-and-inspect step
replaces asking the user:
```markdown
- [ ] **(You)** Click the "Lock" menu item.
- [ ] **(Claude)** Screenshot the menu bar status item; confirm the red lock badge is visible.
```
The triggering action stays `(You)` if it needs a human's hands.

**Time-based checks aren't automatically `(You)`** -- a single frame can't show change over time,
but two-plus spaced screenshots (or accessibility reads) often can:
- A value that should be increasing: prefer a DB-based check if one exists -- more direct than
  reading rendered text.
- A single element blinking: two screenshots roughly half a blink-interval apart proves animation.
- **Multiple elements blinking in lockstep** is a stronger claim -- needs several closely-spaced
  screenshots comparing all elements at each sample, not just two.

Launching the app for any of this still needs the root `CLAUDE.md`'s heads-up/wait/all-clear ritual.

## Presenting durations

Convert `duration_seconds` to `mm:ss` for on-screen comparisons. Keep `display_seconds` on during
testing. Ask "is the time increasing?", not "is it paused?".

## Detect a physical action instead of asking "are you done?"

For a `(You)` action with a verifiable DB/`debug_log` side effect, poll for that change instead of
asking for confirmation -- e.g. loop a `device_event` query every couple of seconds after asking for
a flip. Only ask outright when there's no detectable side effect, or it's ambiguous which action
produced it.

**Before asking for a flip specifically, confirm the device isn't locked** (no lock badge on the
menu bar) -- the device silently refuses flips while locked (no error, just no face-change event),
so polling `device_event` afterward would hang forever with nothing to detect. Unlock first if
locked, unless the scenario is deliberately testing the locked-refusal behavior itself.

## Read debug output

Use `debug_log`, not a live terminal transcript:
```
sqlite3 ~/Library/Application\ Support/TimeFlip/appdata.sqlite \
  "SELECT tag, message, logged_at FROM debug_log ORDER BY debug_log_id DESC LIMIT 20;"
```
`tag` matches `DeveloperMode.DebugTag`'s bracketed prefix.

**After a factory reset, query `device_event` by `device_event_id DESC`, not `MAX(event_number)`.**
The device's own counter restarts from 1 and isn't unique across a reset, while old rows are never
deleted, so `MAX(event_number)` can return either era. `device_event_id` (the local PK) is always
strictly increasing.

## Switch to the test database

`appdata.sqlite` symlinks to `production.sqlite` or `test.sqlite`, re-read only at launch:
```
scripts/use-test-database.sh        # -> test.sqlite (deletes and recreates fresh)
scripts/use-production-database.sh  # -> production.sqlite
```
**Pre-flight, every session, before switching:** confirm `db_type` reads `{"type":"production"}`,
device connected, and a `history` fetch has completed (`debug_log`, `DB refreshed`) -- so real
device history lands in `production.sqlite` first. This is what makes it safe to run anything after,
including a factory reset, without pausing to confirm with the user.

Then: quit, run the test-database script, start the app, query `db_type` as the very first Setup
step -- it must read `{"type":"test"}`; if it reads `production`, **stop immediately**. When done:
quit, run the production-database script, relaunch. `test.sqlite` never carries over -- each session
starts fresh.

**This switch happens once per testing session** (when the user first asks to run the device
tests), not before every individual checklist -- a checklist's own Setup listing "run
`scripts/use-test-database.sh`" describes what a *standalone* run of that checklist needs, not a
mandatory re-wipe when it's one of several checklists run back-to-back in the same session. If
`db_type` already reads `{"type":"test"}` from an earlier checklist this session, skip straight to
confirming that, rather than deleting and recreating `test.sqlite` again.

## Suppress incidental double-taps during a session

The device pauses itself on any physical double-tap -- unconditional firmware behavior, no BLE
command disables it. The only lever is accelerometer sensitivity
(`clickThreshold`/`limit`/`latency`/`window`, each `UInt8` 0-255) in the Device tab's **Double tap**
disclosure (there's no separate "Advanced" section and no "Sync from device" button -- both stale).
Expanding it shows the four fields already at the live device values (auto-synced on every connect,
`debug_log` tag `device-sync`). This is a physical device register, independent of which DB is
active, so snapshot/restore it separately:

1. Record the four field values in `Tests/Bench/device_register_snapshot.json` (gitignored) under a
   timestamp-keyed `double_tap_params_as_at` object -- once per session, before the first change.
2. Set **Window** to `0` (stronger than raising `clickThreshold`, which only needs more force) --
   confirm via `debug_log` tag `double-tap`, `"Params changed: ... win=0"`. This does land in the DB
   (`setting_name='double_tap_settings'` in `setting`).
3. Run the session's checklist(s).
4. Restore the original values from step 1.

If a scenario specifically tests double-tap-to-pause, temporarily restore real sensitivity for just
that scenario, then re-suppress.
