# Automation methods

## Use these, and fix this file when they fall short

**Read this file before running any checklist, and use the method for anything it covers.** Not an
equivalent you wrote from memory: the methods are here because each one was got wrong at least once
first, and most carry a caveat that is invisible until it costs a run (Method 6's single `tell`
block, Method 7's preceding mouse move, Method 12's commit key). An improvised equivalent silently
drops those.

**When a method does not fit, update this file in the same run.** Three shapes, all the same rule:

- **Missing** -- a technique with no method. Append it with the next unused number and link it from
  the step that needed it.
- **Wrong** -- a method whose body no longer works, or whose caveat turns out to be incomplete. Fix
  the method, not the one step that tripped on it.
- **Deliberately not followed** -- a case the method does not cover. Say so *in the method*, as a
  second form or a caveat, rather than leaving the reason in one checklist or in your head.

The bar for anything added or changed is `CLAUDE.md`'s: **verified against a real, live run, never
reasoned about.** A method that has not been executed is a guess with a number on it.

Working from memory instead is what this is for. On 2026-08-09 a verification run built the app with
a command that is not in this file, correctly -- Method 1's form builds *and launches*, which is
unusable under the live-app-interaction ritual, where the build has to happen before the warning and
the launch only after the acknowledgment. The right command was worked out by reading
`scripts/run.sh`, and the gap went unrecorded until somebody asked whether the methods were being
used. It is Method 1's second form now.

The concrete, verified "how" behind every automated step in `Tests/Bench/`/`Tests/Interactive/`.
Each method below is self-contained and independently linkable -- a checklist step that needs one
says so explicitly by **number**, as a link that jumps straight to it:
`[Method: Number 6](../Methods.md#method-6)`. Two steps needing the same technique both point here
rather than duplicating text; a step needing a different technique updates its own reference.

Each method has a permanent number in its heading (`## Method <N>: <name>`) and a matching stable
anchor (`<a id="method-<N>"></a>`) just above it, so `../Methods.md#method-<N>` lands on it directly
rather than the top of the page. **The numbers are stable IDs, not positions -- never renumber.** Discovering a new technique means appending it here
with the next unused number and linking it from the step that needed it (same "verified against a
real, live run" bar as `CLAUDE.md`); reordering or removing a method leaves every other number
untouched so existing `Method: Number <N>` references never silently point at the wrong thing.

`CLAUDE.md` still holds the rules, process, and background facts about app/device behavior; this
file holds only reusable step-execution techniques.

<a id="method-1"></a>
## Method 1: Build the app

`scripts/run.sh` builds+launches in one step, blocking -- background it, poll the log for
`"Build of product"`/`"error:"`. Bundle:
`.build/bundler/apps/TimeFlip/TimeFlip.app/Contents/MacOS/TimeFlip`.

**Second form: build without launching.** The form above starts the app as a side effect, which the
root `CLAUDE.md`'s live-app-interaction ritual cannot use -- there the build has to happen *before*
the hands-off warning and the launch only *after* the acknowledgment, so they have to be separable.
`bundle` does the same work and stops at the bundle; pair it with Method 2 when the app should
actually start.

```toml method
action = "shell"
command = "mint run stackotter/swift-bundler@main bundle TimeFlip"
timeout_seconds = 540
```

Note `swift bundler bundle` is **not** the same command and does not work here (`unable to invoke
subcommand: swift-bundler`) -- the tool is reached through `mint`, as `scripts/run.sh` does. Both
confirmed live 2026-08-09, across five build/launch cycles during the manual-mode verification.

<a id="method-2"></a>
## Method 2: Launch the app

Invoke the built binary directly (inherits the shell's env vars, needed for debug hooks) --
`scripts/run.sh` doesn't reliably pass them through.
```toml method
action = "shell"
command = "nohup ./.build/bundler/apps/TimeFlip/TimeFlip.app/Contents/MacOS/TimeFlip > /dev/null 2>&1 &"
```

**Pair it with Method 3 unless you know the app is down**, but not for the reason this note used to
give. A second instance is no longer possible: the app takes an exclusive lock at startup
(`SingleInstanceLock`) and a duplicate launch writes `TimeFlip is already running; this instance is
exiting.` to stderr and exits 0 before it opens the database or touches the radio. The two status
items and two competing BLE clients that `09b` produced on 2026-08-02 by inlining a bare launch
cannot happen now.

What is left is quieter and still wrong: `Tests/00-test-setup.md` leaves the app running before any
feature checklist starts, so a bare launch is a **no-op**, and a step meaning to observe a fresh
start silently asserts against the instance that was already up. Quit first (Method 3 no-ops when
nothing is running, so the pair restarts and cold-starts alike). The lock is released when the
process dies however it dies, so a relaunch straight after a quit, a crash or a `kill -9` takes it
cleanly (measured 2026-08-10).

<a id="method-3"></a>
## Method 3: Quit the app

`osascript -e 'tell application "TimeFlip" to quit'`. Never `pkill`/`kill` for a real test step --
skips `applicationWillTerminate` (e.g. `pause_on_lock`-on-quit never fires). `pkill` is fine only as
last-resort cleanup.

**Sending the quit is not the same as the app having exited.** `osascript` returns once the app
*acknowledges* the event, and with `pause_on_lock` on the app then pauses and locks the device over
BLE in `applicationWillTerminate` before terminating -- so a step that quits and relaunches can
start a second instance on top of the first. The runnable form therefore polls until the process is
really gone (and fails the step if it never goes, e.g. a modal dialog holding the app open). It also
no-ops when the app isn't running, which a raw `tell ... to quit` does not: AppleScript will *launch*
the app to deliver the event.
```toml method
action = "quit_app"
```

<a id="method-4"></a>
## Method 4: Confirm device reconnect

Query `debug_log` for a fresh `TimeFlip`-tagged `"Login accepted, code=0x02"` row -- don't ask the
user.
```
sqlite3 ~/Library/Application\ Support/TimeFlip/appdata.sqlite \
  "SELECT logged_at, message FROM debug_log WHERE tag='TimeFlip' AND message LIKE 'Login accepted%' ORDER BY debug_log_id DESC LIMIT 1;"
```
Runnable form: `since_id` scopes it to a row *this* restart produced -- pass the baseline the step
captured before quitting (`since_id = "$before_quit_id"`), or `since_id = "$current_log_id"` for
"since this step began".

**A step must pass `since_id` itself.** The `since_id` line in the method body below is documentation
of the shape, not a working default: `methods._merge` fills a method's `$placeholders` from the
**step's** keys only, so a step that omits it leaves `$since_id` literal in the SQL, where SQLite
reads it as a named parameter and the step dies with `Incorrect number of bindings supplied. The
current statement uses 1, and there are 0 supplied.` Every call site passes it explicitly; this was
found the hard way on 2026-08-05 by the one that did not.
```toml method
action = "wait_for_sql"
query = "SELECT message FROM debug_log WHERE tag='TimeFlip' AND message LIKE 'Login accepted%' AND debug_log_id > $since_id ORDER BY debug_log_id DESC LIMIT 1;"
expect_contains = "Login accepted"
since_id = "$current_log_id"
timeout_seconds = 30
```

<a id="method-5"></a>
## Method 5: Grant/verify Accessibility permission

Accessibility (separate from Screen Recording) must be granted to the calling app -- trace it via
`ps -o ppid=,comm= -p <pid>` up from the current shell, under System Settings -> Privacy & Security
-> Accessibility, then fully quit/reopen that app. Canary (a *real* result, not a `-1719` error,
confirms it works):
```
osascript -e 'tell application "System Events" to tell process "Finder" to get name of every menu bar item of menu bar 1'
```

<a id="method-6"></a>
## Method 6: Click a status-item menu item

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
The runner does all of that inside one `osascript` call, so a step only names the item:
```toml method
action = "click_menu_item"
item = "$item"
```

<a id="method-7"></a>
## Method 7: Simulate a real click, double-click, or held press via CGEventPost

AppleScript's `click`/`click at {x, y}` (System Events) never reaches genuine screen-position-based
gestures -- confirmed dead ends for the status item's click-right-half toggle and the auto-pause
stepper arrows' held press: both are raw `NSEvent`-driven hit-tests, not menu/AX actions, and
synthetic AX/coordinate clicks simply never arrive (no effect, and -- once the `click`-tagged debug
print existed to check -- no log line either).

A raw `CGEventPost` (e.g. via Python's `pyobjc`/`Quartz`) *does* arrive correctly, but only if
**both** of the following hold. Each was found the hard way, and each fails silently.

1. `kCGMouseEventClickState` is set explicitly on the down and up events -- omitting it makes macOS
   treat every event as a fresh single click (`clickCount` always `1`), which is the actual root
   cause behind "synthetic double-clicks don't work" (not click speed, a missing metadata field).
2. A `kCGEventMouseMoved` is posted to the target point **first**. A down/up pair carries
   coordinates, but without a preceding move the click is delivered against wherever the window
   server still believes the pointer is -- so it lands on whatever is under the *old* position.
   Confirmed live 2026-07-31 while pairing repeatedly: with no move, one click actuated `Stop Scan`
   instead of the device row 80pt below it, and a later one produced no effect and no `click`-tagged
   log line at all. Adding the move made seven consecutive pairings reliable. Raise the target window
   too (`set frontmost to true`, then `perform action "AXRaise"`), since the click goes to whatever
   window owns that screen point, not to the app you meant.

```python
import Quartz, time
X, Y = <screen point x>, <screen point y>

# (2) Move first -- not optional; see above.
Quartz.CGEventPost(Quartz.kCGHIDEventTap, Quartz.CGEventCreateMouseEvent(
    None, Quartz.kCGEventMouseMoved, (X, Y), Quartz.kCGMouseButtonLeft))
time.sleep(0.3)

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
(`debug_log` `side=right clickCount=1`, a fresh `device_event` row with `paused` flipped) -- both
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

**A synthetic key goes to the frontmost app, not to a process.** `cgevent_key` posts to the HID
tap, so it obeys the same rule as AppleScript `keystroke` (Method 12): whatever is frontmost
receives it. The trap is a step that follows an `ask_user` prompt -- the tester just typed `y` in
the **terminal**, so the terminal is frontmost and the key lands there. Confirmed live on
2026-08-01: an Escape aimed at a rename field echoed `^[` into the terminal and the app never saw
it, failing the step it was setting up. Pass `activate = "TimeFlip"` on the step:

```toml
action = "cgevent_key"
keycode = 53
activate = "TimeFlip"
```

Not the default, because the status-item case must not do it: an `osascript` call while that menu
is open is exactly the collision Method 6 warns about, and there the click that opened the menu has
already brought the app forward.

Get target coordinates from the element's `position`/`size` via accessibility (Read a label or value
via accessibility, below) -- already in points, no pixel conversion needed. Caveat for a stacked
arrow pair (every `SteppedNumberField` has one): both its `image` elements report the **same** rect,
that of the upper chevron (a SwiftUI AX quirk collapsing the pair's custom-drawn glyphs onto one
frame), so `image 2` is no use -- read `image 1` and derive the lower arrow as `image 1`'s center
plus the stack's pitch (`arrowHeight` + `arrowSpacing` in `SettingsLayoutConstants.Stepper`, 11pt).

The pairs are indistinguishable from each other, so **the only thing identifying a row's arrows is
the index**, counted in layout order down the group. `image 1` of the Device tab's Settings group is
auto-pause's up chevron because auto-pause is the first row there. Assert that ordering before
relying on it (`Bench/05b` Setup Step 2 does), or a row inserted above sends the clicks to a
different control with no error to show for it.

Anchor on the target element itself, never on a hand-measured offset from a neighbour. These arrows
were once located by offsetting left from the adjacent text field; when the row was restyled to put
the arrows *after* the value (matching every other stepper in the window) the offset silently
pointed into empty space, and the clicks that stopped landing were invisible to any step that didn't
assert the value actually moved.

<a id="method-8"></a>
## Method 8: Status-item click gesture

The status item's own click-right-half gesture (single-click pause/resume toggle, double-click lock
toggle) is a raw screen-position hit-test (`MenuBarController.swift`), not a menu action. Drive it
with the CGEventPost technique above, at the status item's own `position`/`size` (right half: `x =
position.x + size.width * 0.75`, `y = position.y + size.height / 2` roughly) -- confirmed live for
both the single-click pause/resume toggle and the double-click lock toggle. `handleStatusItemClick`
also logs every real click it receives (`debug_log` tag `click`, `"Status item clicked:
side=left/right clickCount=N ... -> <action>"`), useful to confirm a click (synthetic or real)
actually landed. The trailing `-> <action>` is the `StatusItemClick` the router resolved it to
(`showMenu`, `openSettings`, `lockDevice`, `togglePause`, `togglePauseImmediately`), and ` manualMode`
appears before the arrow while the app is in manual mode. **Assert on that arrow rather than on a
per-branch message**: `1447da4` moved the routing into `MenuBarClickRouter` and deleted the
individual messages each branch used to log, leaving `07i` waiting on `"Left-click while low
battery: ..."`, which no longer existed. The decision is the durable thing to read.

<a id="method-9"></a>
## Method 9: Discovered-device row click

The discovered-device row in the pairing list (Device tab -> TimeFlip section) is a plain
`Text`+`.onTapGesture`, not a `Button` -- neither an AX `click` nor an AX `click at {x, y}` triggers
it. A raw **CGEventPost mouse click at the row's centre** *does* actuate it (confirmed live
2026-07-25: paired a freshly factory-reset device start to finish this way). The runner's
`cgevent_click_element` action does exactly that -- it reads the element's `position`+`size` via
accessibility, then CGEvent-clicks the middle -- so this is a normal script/`(Claude)` step now, not
an ad-hoc "ask the user to click" one. Locate the row by its `AXIdentifier`, `discovered-device-row`
(Method 13), which doesn't depend on the cube being named "TimeFlip"; locating it as `first static
text ... whose name contains "TimeFlip"` also works and skips the "Click a device below to pair with
it." header. Either way the click itself needs Method 7's preceding `kCGEventMouseMoved`, without
which it lands on whatever was under the pointer before. See
`Bench/02b-reset-device-checklist.md` Step 7.

<a id="method-10"></a>
## Method 10: Switch Settings-window tabs

Address the tab by **name**, never by index. Both `title` and `name` read `missing value` on these
buttons, but `description` holds the visible label (`Device`, `Categories`, `Faces`, `Report`,
`App`), so:

`click (first radio button of radio group 1 of group 1 of toolbar 1 of window "TimeFlip Settings"
whose description is "<name>")`

Indices were the original approach and broke silently when the `Categories` tab was inserted second:
every `radio button 2` quietly became Categories rather than Faces, and `3` became Faces rather than
App, so steps went on selecting *a* tab and passing while testing the wrong one. A name that doesn't
match errors `-1719 Invalid index` instead, which is the point -- though note `act_applescript`
retries, so a mistyped name spends the full `timeout_seconds` before reporting it.

Pass the tab name as `tab`. The click retries until the Settings window actually exists, so no
fixed sleep is needed after opening it:
```toml method
action = "applescript"
script = """
tell application "System Events"
    tell process "TimeFlip"
        click (first radio button of radio group 1 of group 1 of toolbar 1 of window "TimeFlip Settings" whose description is "$tab")
    end tell
end tell"""
```

<a id="method-11"></a>
## Method 11: Read a label or value via accessibility

Read any label/value via accessibility (`static text`/control `value`) -- no screenshot needed. Dump
`entire contents` of the window to find an element's path; re-derive each time, since indices shift
with which disclosures are expanded.
Reading which Settings tab is selected is common enough to share -- `tab` is the tab's name (see
Method 10 on why these are addressed by name, not index), and it returns `1` when that tab is the
selected one:
```toml method
action = "applescript"
script = """
tell application "System Events"
    tell process "TimeFlip"
        return value of (first radio button of radio group 1 of group 1 of toolbar 1 of window "TimeFlip Settings" whose description is "$tab")
    end tell
end tell"""
```

<a id="method-12"></a>
## Method 12: Edit a text field

Focus it, `cmd+A`, type the value, `keystroke return`. Every typeable value field in the Settings
window is a **`SteppedNumberField`** -- the Device tab's auto-pause, LED brightness and blink
interval and the four double-tap params, plus the App tab's daily-reset hour, battery-warning level
and fetch-history interval -- and they all commit the same way, so one sequence covers all of them.

- A `SteppedNumberField` commits **only** on Return or focus loss, deliberately, so typing `15`
  isn't clamped to `1` on the way. Typing alone changes nothing: confirmed live, a typed value
  produced no DB write and no `debug_log` row at all until committed. Getting this wrong fails
  quietly -- there is no error, just an assertion that times out on a row that was never written
  (see the LED bug in `Bench/06b`'s history, and `03b`/`05b` on 2026-07-31).
- `keystroke return` commits and **keeps focus on the field**, so it works both for a single edit
  and for several rapid edits to the same field. Use it everywhere rather than picking per case.
  Verified live: `10`/`50`/`95` each followed by Return gave three changed+saved pairs and exactly
  one debounced device write.
- `keystroke tab` also commits, but moves focus on, so it can't be used between values in a rapid
  sequence. There is no case that needs it -- prefer Return.

**Auto-pause and the double-tap params used to commit live on every keystroke** and their steps
carried no commit key. They became `SteppedNumberField`s when every stepper in the window was
unified, which silently turned those steps into no-ops. If a typing step ever stops writing
anything, this is the first thing to check.

`keystroke` always targets the frontmost app
regardless of which process the `tell` addresses -- run `tell application "TimeFlip" to activate`
before every sequence and confirm with `name of first process whose frontmost is true`. A plain
`click` on a field doesn't reliably set focus either -- follow with `set focused of e to true` and
confirm it reads `true`, all in one `osascript` call (a stale element reference doesn't survive
across calls).

<a id="method-13"></a>
## Method 13: Click a button, checkbox, or slider

`click button "..."` / `set value of checkbox ... to true` -- confirm each via `debug_log`/DB the
first time it's actually used.

**A SwiftUI `Button` in the Settings window exposes no readable name at all.** Not merely empty:
`AXTitle`, `AXDescription` and `AXHelp` are absent from the element's attribute list entirely, and
it has no children to read either, so `button "Forget Device"` matches nothing and only the index
works. Addressing by index is what silently broke the tab steps when a tab was inserted (Method 10),
and here the two adjacent candidates are Forget Device and Reset Device, one of which wipes the cube.

The fix is to name the control, not to work around it -- but **`.accessibilityLabel` does not work
here**. Verified against the device 2026-07-31: with the label applied, `AXDescription` still never
appears. `.accessibilityIdentifier` does work; it adds `AXIdentifier`, which System Events can
filter on:

```applescript
tell group 3 of scroll area 1 of group 1 of window "TimeFlip Settings"
    click (first button whose value of attribute "AXIdentifier" is "forget-device")
end tell
```

Identifiers in the pairing section (`TimeFlipSettingsView.swift`): `forget-device`, `reset-device`,
`scan-for-devices` (one identifier for both titles -- read `title` or the debug log to tell which
mode it's in), and `discovered-device-row` on every result row.

Two traps when filtering on `AXIdentifier`:

- A `whose value of attribute "AXIdentifier" is ...` clause over `every UI element` **errors**
  (`-1728`) as soon as it meets a sibling lacking the attribute -- checkboxes and progress
  indicators here do. Iterate with a `try` inside instead. It's safe over `every button`, where all
  the candidates have one.
- An identifier makes an element *findable*, not *clickable*. The discovered-device row still needs
  a real CGEvent click (Method 9).

**If a control you need can't be addressed by name, add an identifier to the source** rather than
reaching for an index.

Whatever the selector, the app logs `Button clicked: <name>` under the `click` tag, so a step can
prove the intended control fired instead of assuming it -- worth doing on anything destructive even
when addressing by identifier.

<a id="method-14"></a>
## Method 14: Auto-pause stepper arrows

The auto-pause field's up/down stepper arrows are custom `Image`+`onLongPressGesture` views, not
real controls -- AX/coordinate clicks via AppleScript don't move them, but the CGEventPost technique
above (see the coordinate caveat there) does: confirmed live for a plain click, a held press (both
directions, full deceleration curve), and the hold-interrupted-by-window-close compound gesture.

<a id="method-15"></a>
## Method 15: Expand or collapse a disclosure group

A `DisclosureGroup` shows as role `AXDisclosureTriangle` ("UI element", no readable label) --
identify it by position among siblings, `click` to expand/collapse.

<a id="method-16"></a>
## Method 16: Confirm a confirmation-dialog sheet

A `.confirmationDialog` opens as `sheet 1 of window ...`, not a button on the window itself --
address it that way; its buttons' `title` is also `missing value`, use `description` to tell them
apart (e.g. `Cancel` vs. the destructive confirm).

<a id="method-17"></a>
## Method 17: Screenshot-based visual confirmation

For a **static** state that isn't accessibility-readable -- the status item is a custom-drawn
`NSStatusItem`, so its lock badge and pause/play icon can't be read via `static text`/control
`value` -- capture the screen and look, rather than asking a human (when *you*, an AI, are running
the tests). How:
```bash
screencapture -x /tmp/tf-menubar.png    # -x = silent (no shutter sound); whole screen
```
Then Read `/tmp/tf-menubar.png` and inspect the **top-right menu bar**: the red lock badge sits to
the left of the activity indicator, which is itself a pause icon (⏸) or a play icon (▶). Capturing
the whole screen and looking at the top-right is simpler and more robust than guessing the status
item's shifting x-position; crop to a region (`-R x,y,w,h`) only if you need the detail.

A step that needs this reads e.g. `Check the menu bar shows the pause icon (⏸)` and cites `Method:
Screenshot-based visual confirmation (../Methods.md)`. The standalone script runner has no vision,
so for the same step it instead asks the human to look and answer y/n -- same check, different
observer.

**Time-based checks aren't automatically `(You)`** -- a single frame can't show change over time,
but two-plus spaced captures (or accessibility reads) often can:
- A value that should be increasing: prefer a DB-based check if one exists -- more direct than
  reading rendered text.
- A single element blinking: two captures roughly half a blink-interval apart proves animation.
- **Multiple elements blinking in lockstep** is a stronger claim -- needs several closely-spaced
  captures comparing all elements at each sample, not just two.

Capturing the already-running app needs no special ritual; only *launching* the app for this needs
the root `CLAUDE.md`'s heads-up/wait/all-clear ritual.

<a id="method-18"></a>
## Method 18: Presenting durations

Convert `duration_seconds` to `mm:ss` for on-screen comparisons. Keep `display_seconds` on during
testing. Ask "is the time increasing?", not "is it paused?".

<a id="method-19"></a>
## Method 19: Detect a physical action instead of asking "are you done?"

For a `(You)` action with a verifiable DB/`debug_log` side effect, poll for that change instead of
asking for confirmation -- e.g. loop a `device_event` query every couple of seconds after asking for
a flip. Only ask outright when there's no detectable side effect, or it's ambiguous which action
produced it.

**Before asking for a flip specifically, confirm the device isn't locked** (no lock badge on the
menu bar) -- the device silently refuses flips while locked (no error, just no face-change event),
so polling `device_event` afterward would hang forever with nothing to detect. Unlock first if
locked, unless the scenario is deliberately testing the locked-refusal behavior itself.

<a id="method-20"></a>
## Method 20: Read debug output

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

<a id="method-21"></a>
## Method 21: Switch to the test database

`appdata.sqlite` symlinks to `production.sqlite` or `test.sqlite`, re-read only at launch:
```
scripts/switch-database.sh              # -> swaps to whichever of the two isn't in use
scripts/switch-database.sh test         # -> test.sqlite (deletes and recreates fresh)
scripts/switch-database.sh test -keep   # -> test.sqlite, preserved as-is (resuming a mid-run batch)
scripts/switch-database.sh prod         # -> production.sqlite (no-op if already there)
```
Naming the target is what a script should do (it says where it wants to end up regardless of where
it started); the bare swap is the convenience form for switching by hand. `test` always rebuilds,
even when test.sqlite is already the database in use -- `-keep` is what suppresses that.
**Pre-flight, every session, before switching:** confirm `db_type` reads `{"type":"production"}`,
then restart the app and confirm a fresh fetch against production has completed (`debug_log`, tag
`hist-done`, `"history fetch complete:"`) -- so real device history lands in `production.sqlite`
first. This is what makes it safe to run anything after, including a factory reset, without pausing
to confirm with the user. Don't just wait on the periodic fetch timer instead
(`fetch_history_interval_seconds`, a developer may have set that as long as 15 minutes) --
restarting forces the fetch immediately via the app's own startup backfill.

Two things to match carefully here. **Don't require `trigger=startup`:** the periodic timer starts
at launch and can tick before the startup fetch is reached on a slow connect, in which case the
startup call is folded into the one already running and never logs a `trigger=startup` row at all
(the work still happens, under the other trigger, followed by a `trigger=debounce` re-run). Scope
to the newest `Login accepted` instead and accept any completed fetch after it, as
`00-test-setup.md` Step 7 does. **And don't match the older `"DB refreshed"` text:** that only ever
logs on the branch where nothing changed, and never appears for a fetch that pulls a real backlog.

Then: quit, run the test-database script, start the app, query `db_type` as the very first Setup
step -- it must read `{"type":"test"}`; if it reads `production`, **stop immediately**. When done:
quit, run the production-database script, relaunch. `test.sqlite` never carries over -- each session
starts fresh.

**This switch happens once per testing session** (when the user first asks to run the device
tests), not before every individual checklist -- a checklist's own Setup listing "run
`scripts/switch-database.sh test`" describes what a *standalone* run of that checklist needs, not a
mandatory re-wipe when it's one of several checklists run back-to-back in the same session. If
`db_type` already reads `{"type":"test"}` from an earlier checklist this session, skip straight to
confirming that, rather than deleting and recreating `test.sqlite` again.

<a id="method-22"></a>
## Method 22: Suppress incidental double-taps during a session

The device pauses itself on any physical double-tap -- unconditional firmware behavior, no BLE
command disables it. The only lever is accelerometer sensitivity
(`clickThreshold`/`limit`/`latency`/`window`, each `UInt8` 0-255) in the Device tab's **Double tap**
disclosure (there's no separate "Advanced" section and no "Sync from device" button -- both stale).
Expanding it shows the four fields already at the live device values (auto-synced on every connect,
`debug_log` tag `device-sync`). This is a physical device register, independent of which DB is
active, so snapshot/restore it separately:

1. Record the four field values before the first change -- **capture** them from
   `double_tap_settings` so they're captured under the running scenario
   (see `scripts/testrunner/README.md`), and restore from there at the end. (`03b` Scenario B
   Step 1 does exactly this: four `sql_query` captures of `clickThreshold`/`limit`/`latency`/
   `window`.)
2. Set **Window** to `0` (stronger than raising `clickThreshold`, which only needs more force) --
   confirm via `debug_log` tag `double-tap`, `"Params changed: ... win=0"`. This does land in the DB
   (`setting_name='double_tap_settings'` in `setting`).
3. Run the session's checklist(s).
4. Restore the original values from step 1.

If a scenario specifically tests double-tap-to-pause, temporarily restore real sensitivity for just
that scenario, then re-suppress.

<a id="method-23"></a>
## Method 23: Close the Settings window

`click button 1 of window "TimeFlip Settings"` (button 1 is the window's red close button). Guard it
with `if exists window "TimeFlip Settings"` so it's a no-op when the window isn't open -- clicking a
non-existent element errors otherwise:

```applescript
tell application "System Events"
    tell process "TimeFlip"
        if exists window "TimeFlip Settings" then click button 1 of window "TimeFlip Settings"
    end tell
end tell
```
```toml method
action = "applescript"
script = """
tell application "System Events"
    tell process "TimeFlip"
        if exists window "TimeFlip Settings" then click button 1 of window "TimeFlip Settings"
    end tell
end tell"""
```

A checklist that opens the Settings window closes it again at the end (or whenever the following
steps no longer need it) so the next checklist starts with no stray window open -- the window
otherwise persists for the whole run, since each reopen just re-shows the already-open window.

<a id="method-24"></a>
## Method 24: Query the DB

The reads and writes checklists make over and over, in one place. A step names the variant it wants
(`Method 24.a`) and supplies the parameter, so `use = "method-24.a"` + `setting = "db_type"` reads
that setting. Sub-blocks are parameterised where the only difference between call sites is a name --
one entry per literal query would be twenty near-identical copies of the same `SELECT`.

Every sub-block is a plain `sql_query` (read now, once). A step that needs to *wait* for the value
adds `action = "wait_for_sql"` plus `expect`/`expect_contains`, which overrides the action while
keeping the query -- that's how the same SQL serves both an immediate read and a poll.

- **a** -- a setting's raw `setting_value` (`setting`), e.g. `db_type`, `auto_pause_minutes`,
  `pause_on_lock`, `low_battery_level`.
- **b** -- the current max `debug_log_id`, the baseline a later step scopes its search to.
- **c** -- one column of the latest `device_event` row (`column`), by `device_event_id DESC` -- e.g.
  `paused`, `event_number`, `duration_seconds`. Never `MAX(event_number)`: the device's counter isn't
  unique across a factory reset (see Method 20).
- **d** -- the latest `debug_log` message for a tag (`tag`).
- **e** -- the latest `debug_log` message for a tag (`tag`) newer than a baseline (`since_id`), i.e.
  a row *this* step or scenario produced rather than a stale one from earlier in the run.
- **f** -- one JSON field of a setting (`setting`, `field`), e.g. `clickThreshold` of
  `double_tap_settings`.
- **g** -- the live battery `level`, flap-robust: the **higher of the two most-frequent** readings,
  since the device's reported level oscillates by 1-2% between samples.
- **h** -- the face the device is *not* currently resting on, as a name (`Break`/`Meeting`) -- what
  to ask a person to flip to.
- **i** -- overwrite a setting (`setting`, `value`). A write, so it's a `sql_exec`. The value goes in
  **raw**, so a JSON-shaped setting takes the whole object (`{"enabled":false}`), never a bare
  scalar: the app reads these with `json_extract` and falls back to its *default* when the field
  isn't there, which is silent. Verify such a write with **f** (the field the app reads), not **a** --
  **a** hands back whatever was written, so a malformed value confirms itself.
- **j** -- the latest *real* `battery` row, skipping the `level=nil` placeholder the app logs before
  the first reading arrives.

```toml method
[a]
action = "sql_query"
query = "SELECT setting_value FROM setting WHERE setting_name='$setting';"

[b]
action = "sql_query"
query = "SELECT MAX(debug_log_id) FROM debug_log;"

[c]
action = "sql_query"
query = "SELECT $column FROM device_event ORDER BY device_event_id DESC LIMIT 1;"

[d]
action = "sql_query"
query = "SELECT message FROM debug_log WHERE tag='$tag' ORDER BY debug_log_id DESC LIMIT 1;"

[e]
action = "sql_query"
query = "SELECT message FROM debug_log WHERE tag='$tag' AND debug_log_id > $since_id ORDER BY debug_log_id DESC LIMIT 1;"
since_id = "$current_log_id"

[f]
action = "sql_query"
query = "SELECT json_extract(setting_value, '$.$field') FROM setting WHERE setting_name='$setting';"

[g]
action = "sql_query"
query = "SELECT bl FROM (SELECT CAST(substr(message, 7, instr(message, ' threshold') - 7) AS INTEGER) AS bl, COUNT(*) AS n FROM debug_log WHERE tag='battery' AND message NOT LIKE 'level=nil%' GROUP BY bl ORDER BY n DESC LIMIT 2) ORDER BY bl DESC LIMIT 1;"

[h]
action = "sql_query"
query = "SELECT CASE WHEN (SELECT device_face FROM device_event ORDER BY device_event_id DESC LIMIT 1) = 8 THEN 'Meeting' ELSE 'Break' END;"

[i]
action = "sql_exec"
query = "UPDATE setting SET setting_value = '$value' WHERE setting_name = '$setting';"

[j]
action = "sql_query"
query = "SELECT message FROM debug_log WHERE tag='battery' AND message NOT LIKE 'level=nil%' ORDER BY debug_log_id DESC LIMIT 1;"
```

<a id="method-25"></a>
## Method 25: Read the status-item menu's item names

What the dropdown currently offers, which is how the device's live state is read from the UI:
`Lock` vs `Unlock` and `Pause` vs `Resume` are mutually-exclusive labels reflecting it. Opens the
menu, reads every item name, and dismisses with `key code 53` -- all in one `tell` block, for the
reason Method 6 gives. A step asserts against the returned comma-separated list, e.g.
`expect_contains = "Unlock"` to confirm the device reads as locked.
```toml method
action = "applescript"
script = """
tell application "System Events"
    tell process "TimeFlip"
        tell menu bar item 1 of menu bar 2
            click
            delay 0.4
            set names to name of every menu item of menu 1
        end tell
        key code 53
    end tell
end tell
return names"""
```

<a id="method-26"></a>
## Method 26: Pick an item from a right-click context menu

A SwiftUI `.contextMenu` is **invisible to accessibility**, so none of the usual approaches work.
Established live on 2026-08-01 against the Categories tab's name column:

- The element advertises `AXShowMenu` in `name of every action`, and `perform action "AXShowMenu"`
  **returns success while opening nothing**. A failure you cannot detect from its return value.
- After a real `CGEventPost` right-click, `count of menus` reports **0** on the element, **0** on the
  process, and no new window appears. The menu is nonetheless on screen -- proven by
  `screencapture` -- so an AX-based check would call it absent and be wrong.

So it is driven purely by coordinate. Right-click the element, wait for the menu to draw, then
left-click at an offset from that same point: the menu's top-left lands where you clicked.

```toml method
action = "cgevent_context_menu_pick"
element = "$element"
```

`anchor` (default `0.9`) is where across the element's width to right-click. Near the right-hand end
is deliberate: on a fixed-width column a short label leaves most of the column bare, and that bare
part is the hit area a `contentShape(Rectangle())` exists to claim -- clicking there proves the hit
area as well as the menu. `item_dx`/`item_dy` (default `30`/`12`) reach the first item; a menu with
more needs the offset stepped by its row height, which has to be **measured, not assumed**.

`anchor_dx` (default `0`) adds a pixel offset after the anchor, for a target inside no element at
all. A `LabeledContent` row is the case: accessibility exposes only the label and the value, and the
gap between them -- which is most of the row, and the part its `contentShape(Rectangle())` exists to
claim -- belongs to neither. Anchor off the label and step right by pixels; expressing that as a
fraction of the label's width would be a number that changes with the label's text.

**Selectable text takes the right-click before any of this.** A `LabeledContent` value is selectable
on macOS, and selectable text hands its right-click to AppKit, which answers with "Look Up",
"Translate", "Search With Google" and never opens the SwiftUI menu at all. Adding a `.contextMenu`
to the text does not win that fight; `.textSelection(.disabled)` has to come first. Measured on the
Device tab's name on 2026-08-02, screenshotted with the name highlighted blue under the system menu.
If a right-click on a *label* works and the same right-click on its *value* does not, this is why.

Verified end to end: right-click a category name, click Edit, and the row's `text field` count goes
from 2 to 3 as the inline rename field replaces the name, focused and pre-filled.

**Do not reach for `screencapture` to confirm a context menu opened in a step** -- capture proves it
to a human reading a transcript, but the step itself should assert the *consequence* (the field that
appeared, the value that changed), which is readable.

<a id="method-27"></a>
## Method 27: Read the status item's rendered title

The status item's **text** is accessibility-readable, even though its custom-drawn glyphs are not
(Method 17 covers those). `MenuBarController.updateStatusView` assigns `button.attributedTitle`, and
`AXTitle` carries the resulting string, so the activity name and the duration beside it can be
asserted directly instead of screenshotted. Confirmed live 2026-08-05: the read returned
`TEST  Meeting   0:00:00`.

```toml method
action = "applescript"
script = """
tell application "System Events"
    tell process "TimeFlip"
        return title of menu bar item 1 of menu bar 2
    end tell
end tell"""
```

What the string holds, in order: the database badge (`TEST`, present only on the test database), the
activity label (the current face's **category** name, or `Idle`), and the duration. Separators are
runs of spaces, so match a substring (`expect_contains = "5:00:00"`) rather than the whole title.

**Pause the device before asserting a duration.** `MenuBarController.currentDuration` returns the
category total alone while paused and adds the running segment's elapsed seconds otherwise, so an
unpaused read drifts between the query and the comparison and only ever supports a loose match.
Paused, the rendered figure is exactly the total and an exact string assertion holds.

Still unreadable, and still needing Method 17: the pause/play icon, the red lock badge, and the
over-limit colouring, none of which are text.

<a id="method-28"></a>
## Method 28: Read the Report tab's totals

The Report tab's rows **are** accessibility-readable, so the figures are asserted directly rather
than screenshotted. Each row contributes two `static text` elements in view order -- the category
name, then its duration -- inside the tab's scroll area. Joining them with `|` gives one string per
read, e.g. `Unassigned|4:55|Break|3:54|Meeting|1:57|`, which carries the names, the durations **and
their order** (longest first) in a single value. Confirmed live 2026-08-08.

Match a row with `expect_contains = "<Category>|<duration>|"`, which pins a name to the duration
next to it without depending on where that row sorts. Asserting the whole string only works when the
range is known to hold nothing else.

```toml method
action = "applescript"
script = """
tell application "System Events"
    tell process "TimeFlip"
        set out to ""
        repeat with t in static texts of scroll area 1 of group 1 of group 1 of window "TimeFlip Settings"
            set out to out & (value of t) & "|"
        end repeat
        return out
    end tell
end tell"""
```

**The calendars are addressed by index, not by name** -- because AppleScript cannot see their
names, not because they lack them. The day cells and month arrows are properly labelled
(`AXDescription` = `Monday, 3 August 2026`, `Previous month`), confirmed on 2026-08-08 by querying
the accessibility API directly. System Events disagrees, and misleadingly: `description` on these
reads back as the role (`button`) and `attributes of` omits `AXDescription` entirely, so from
AppleScript they look unlabelled. Nothing here can match `whose description is ...`, so index it is.

Worth knowing before filing an accessibility bug against any SwiftUI control on this evidence: a
missing name in System Events is not a missing name. `AXAttributedDescription` also exists on these
and cannot be read from AppleScript at all -- the AppleEvent handler simply fails.

The indices are stable by construction rather than by luck: each
calendar contributes exactly 2 arrow buttons then 42 day cells, in reading order, and the grid is
always six weeks whatever the month. So within `group 1 of group 1 of window "TimeFlip Settings"`:

| Buttons | What |
| --- | --- |
| 1, 2 | **From** calendar: previous month, next month |
| 3-44 | **From** calendar: the 42 day cells, top-left to bottom-right |
| 45, 46 | **To** calendar: previous month, next month |
| 47-88 | **To** calendar: its 42 day cells |

Cell `n` (0-based) of a calendar showing month `M` is the `n`th day from the start of the week
containing `M`'s first day -- the leading cells belong to the previous month and are real, clickable
dates. A disabled cell (a future date, or one before the start) swallows the click silently, so a
step that clicks one and expects a change fails on the assertion rather than on the click. Confirmed
live: clicking button 3 with August 2026 shown logged `From calendar picked 2026-07-27`.

Every pick is logged under the `report` tag (`<title> calendar picked yyyy-MM-dd`), followed by the
resolved range and how many categories it found
(`Report yyyy-MM-dd HH:MM -> yyyy-MM-dd HH:MM: N categories`). Assert against that rather than
assuming an index landed where it was meant to.

<a id="method-29"></a>
## Method 29: Answer the manual-mode offer

The retry-or-manual dialog is an **`NSAlert`**, not a SwiftUI `.alert`, deliberately: every SwiftUI
one in this app hangs off a view inside the Settings window, and this has to be answerable when no
window is open at all, which is the usual state of an `LSUIElement` app at startup.

That makes it the one dialog here whose buttons are properly named. It is `window 1` of the process
(`role AXWindow`, `subrole AXDialog`, and its own `name` empty), and its buttons carry a real
`name` **and** `title` -- unlike every SwiftUI `Button` in the Settings window, which exposes
neither (Method 13). So it is addressed by name, with no identifier needed and no CGEvent click:

```applescript
tell application "System Events" to tell process "TimeFlip" to ¬
    click button "Switch to Manual Mode" of window 1
```

Confirmed live 2026-08-09, for both buttons. The two titles are `Retry` and
`Switch to Manual Mode`; the alert's two `static text` elements carry the headline and body, so a
step can assert it is the right dialog before answering it.

`count of windows` is the cheapest assertion that it is up (`1`) or gone (`0`), and the same read is
what proves the app did **not** re-raise it after an answer.

```toml method
action = "applescript"
script = """
tell application "System Events"
    tell process "TimeFlip"
        click button "$button" of window 1
    end tell
end tell"""
```

**The app is blocked while it is up.** `runModal()` holds the main thread, so `osascript`-driven
quits are refused (`User cancelled. (-128)`) and anything the app queued runs only once it closes.
Answer the dialog before quitting, and never `pkill` past it.

<a id="method-30"></a>
## Method 30: Read the dropdown's items with their enabled state

Method 25 returns the item **names**, which is enough to read the device's live state from the
mutually-exclusive labels. This returns `name=enabled` pairs instead, for the separate question of
whether an item can be *chosen* -- the two diverge, and manual mode is where they do: `Resume` is
live there while `Lock` is dead beside it.

Same one-`tell`-block rule as Method 6: opening the menu and reading it must not be split across two
`osascript` calls. Returns e.g.
`Settings...=true; missing value=false; Resume=true; Lock=false; Quit=true;` -- the `missing value`
is the separator, which has no name and is never enabled.

```toml method
action = "applescript"
script = """
tell application "System Events"
    tell process "TimeFlip"
        tell menu bar item 1 of menu bar 2
            click
            delay 0.4
            set names to ""
            repeat with mi in every menu item of menu 1
                set names to names & (name of mi) & "=" & (enabled of mi) & "; "
            end repeat
        end tell
        key code 53
    end tell
end tell
return names"""
```

Match a single item with `expect_contains = "Lock=false"`, which pins that item's state without
depending on what else is in the menu or what order it is in. Confirmed live 2026-08-09.
