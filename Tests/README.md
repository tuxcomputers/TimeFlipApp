# Tests directory -- history and context

> **For future Claude sessions: you do not need to read this file to run the device tests.**
> Everything you actually need is in [`CLAUDE.md`](CLAUDE.md) in this same directory -- it's kept
> deliberately minimal, and every fact in it has been verified against a real, live test run. This
> file exists purely for historical interest: the discovery process, the dead ends, and the
> reasoning behind why things ended up the way they are in `CLAUDE.md`. If you're only here to run
> a checklist, go read `CLAUDE.md` instead and skip this.

This file is where longer backstory goes when a `CLAUDE.md` entry is added -- the *why* and *how it
was found*, not the operational fact itself (that belongs in `CLAUDE.md`, kept short). Organized
roughly by the section of `CLAUDE.md` each story explains.

## Bench used to require a human for almost everything

The Bench/Interactive split originally existed because nobody had checked whether the app's
menu-bar status item and Preferences window could actually be driven by AppleScript/System Events
at all -- so anything involving a click, a typed value, or reading on-screen state defaulted to
`(You)`, "just in case." Bench's `(Claude)` steps were limited to DB queries and launching/quitting
the app; almost every UI interaction was `(You)`.

That assumption turned out to be wrong once actually tested, in one focused session
(2026-07-19): quitting gracefully, reading `debug_log`, launching the app directly, clicking the
status-item menu, switching Preferences tabs, reading static text, and typing into fields were all
verified to work via System Events -- see the entries below. Once that was confirmed, essentially
every Bench checklist was rewritten to drop its `(You)` steps and the actor labels were removed
from that whole folder, since there was no longer more than one possible actor for any step there.

## Quit vs. kill: the discovery that started this

The first real question was mundane: when cleaning up a launched instance of the app between test
runs, is `pkill -f "TimeFlip.app/Contents/MacOS/TimeFlip"` good enough, or does it matter that it's
a hard kill rather than a real quit?

It matters a lot. `ApplicationDelegate.applicationShouldTerminate` is where the
`pause_on_lock`-before-quit behavior lives (see `04-lock-and-pause-on-lock-checklist.md`) --
logging `"Quit requested; pause_on_lock enabled, pausing and locking device before exit"` then
`"Pause+lock on quit complete, terminating now"`. A `pkill`/signal-based kill bypasses AppKit's
whole termination lifecycle -- neither `applicationShouldTerminate` nor `applicationWillTerminate`
ever runs, so that log sequence (and the real BLE pause+lock commands it sends) simply never
happens. A checklist step that asserts on graceful-quit behavior after a `pkill` would be checking
something that didn't occur, silently.

The fix was `osascript -e 'tell application "TimeFlip" to quit'` -- a standard Apple Event that
every AppKit app responds to out of the box, no System Events or Accessibility permission required.
Verified by running it against the real app and checking `debug_log` immediately after: the exact
same three-line sequence a real Cmd+Q produces showed up, and the process actually exited. This is
also how "confirm it reconnects" stopped needing to be asked of the user at all -- every successful
BLE login already logs `"Login accepted, code=0x02"` (`TimeFlipBLEDevice.swift`), so launching plus
a `debug_log` query fully replaces "(You) start the app and confirm it reconnects."

One side effect worth remembering: these were run as ad hoc diagnostics directly against
`production.sqlite` (not `test.sqlite`), which meant a quit with `pause_on_lock` enabled really did
pause and lock the real physical device. That turned out to be harmless only because the exact same
log sequence was already present in `debug_log` from earlier the same day, before any of this
testing began -- meaning `pause_on_lock` was already the device owner's normal daily configuration,
not something newly triggered. That's a coincidence, not a guarantee -- hence the `CLAUDE.md` rule
to always use the test-database workflow for anything beyond this kind of narrow mechanics check.

## The Accessibility permission saga

Full UI-element scripting (clicking a menu item, typing into a field) needs the calling process to
have Accessibility access granted in System Settings. This is a **separate** grant from Screen
Recording, which had already been sorted out earlier in the same session (needed for
`screencapture`-based screenshot verification) by enabling it for Visual Studio Code and restarting
VS Code.

The first attempts at Accessibility all failed with `"osascript is not allowed assistive access."
(-1719)`. Confusingly, a *shallow* System Events query -- `tell application "System Events" to get
name of every process` -- succeeded even without the grant, which briefly looked like evidence that
things were working. They weren't: that call doesn't touch another app's UI element tree at all, so
it doesn't require Accessibility. Drilling into a specific process's actual UI elements (`tell
process "X" to get name of every menu bar item of menu bar 1`) is what actually needs the
permission, and that kept failing. This is why `CLAUDE.md` calls out that exact canary command
specifically, rather than "try some System Events command."

Finding *which* app needed the grant took tracing the real process tree, since the Bash tool runs
under a chain of processes, not directly as a user-facing app:
```
pid=16574 -> /bin/bash
pid=56114 -> .../anthropic.claude-code-.../native-binary/claude
pid=55575 -> .../Code Helper (Plugin).app/.../Code Helper (Plugin)
pid=55557 -> /Applications/Visual Studio Code.app/Contents/MacOS/Code
```
So the actual TCC-relevant app is Visual Studio Code -- the same one that needed the Screen
Recording grant. The user found it under System Settings -> Privacy & Security -> Accessibility
(easy to confuse with the top-level "Accessibility" sidebar item, which is a completely different
settings page for accessibility *features* like VoiceOver/Zoom -- that page was checked first by
mistake and has no per-app permission list at all). Toggling VS Code on there, then fully quitting
and reopening VS Code, made the canary command succeed for real, returning
`Apple, Finder, File, Edit, View, Go, Window, Help` instead of erroring.

Worth noting for later: this Mac is Jamf-managed (`JamfDaemon` was running in the process list), and
some entries in that same Accessibility list showed `"This setting has been configured by a
profile"` (e.g. `bash`, `Terminal`, `jamfRemoteAssist`). An MDM profile could in principle lock the
whole list down to IT-pre-approved apps only, which would have made this ungrantable from the user
side at all. It didn't block VS Code here, but if this ever needs re-granting on a differently
configured machine and the toggle won't stick or is greyed out, that's almost certainly why, and
it's not something to try to work around (e.g. by editing `TCC.db` directly) -- that's a real
security boundary set by whoever administers the machine.

## Exploring the Preferences window's accessibility tree

With Accessibility working, the next question was whether the same approach reaches *inside* the
Preferences window, not just the status-item menu -- and if so, what its actual element structure
looks like, since none of it had ever been introspected before.

Clicking "Preferences..." in the status-item menu (verified first, since that's what any checklist
step opening Preferences would actually do) opened a real window visible to System Events:
`get name of every window` returned `TimeFlip Settings`. A first attempt to switch tabs assumed a
standard `tab group` element (`click radio button "Device" of tab group 1 of window ...`) -- that
failed with `"Can't get tab group 1 ... Invalid index."`, because SwiftUI's `.tabItem`-style picker
here doesn't expose as a `tab group` at all. Dumping `entire contents` of the window and grepping
for `tab`/`radio`/`Device`/`Facets`/`Report` found the real structure: a `radio group 1 of group 1
of toolbar 1`, containing three `radio button`s. Asking for `title` of those buttons returned
`missing value` for all three -- unhelpful -- but `description` returned the actual label
(`"Device"`, etc.), which is the attribute that actually identifies which button is which.

Clicking `radio button 1` and re-dumping `entire contents` confirmed the payoff: every SwiftUI
`Text`/`LabeledContent` shows up as a real, separately-addressable `static text` element with its
exact displayed string as the value -- e.g. `static text Connection` immediately followed by
`static text Connected`, and `static text Battery` followed by `static text 22%`. That means exact
text can be read directly, with no screenshot, no Screen Recording permission, and no risk of
misreading a pixel -- strictly better than the screenshot-based approach for anything that's pure
text. Screenshots remain the only option for the status item's own custom-drawn icon/badge (that's
one rendered `NSImage`, not decomposed into sub-elements the way a SwiftUI view's accessibility
tree is) and for color/animation, which isn't exposed as any queryable AX attribute regardless of
which control renders it.

Typing into a field was verified the same way: found the auto-pause field
(`text field 1 of group 2 of scroll area 1 of group 1`), focused it, selected all with `cmd+a`,
typed `4`, pressed Tab to commit, and confirmed `auto_pause_minutes` in the DB actually read
`{"minutes":4}` immediately after -- then repeated with `0` to reset it back to a clean state
before quitting. This is what established the specific focus/select-all/type/tab pattern documented
in `CLAUDE.md` -- earlier guesses (e.g. `set value of tf to "4"` without focusing/committing first)
were not tried in detail because this pattern worked on the first real attempt.

Not verified in that session, and worth confirming for real the first time a checklist actually
needs them, rather than assuming: disclosure-group expand/collapse clicks, slider drags, checkbox
toggles, the "Scan for Devices" discovered-device list, and the destructive Reset Device
confirmation dialog. They're expected to work via the same general System Events mechanism, but
"expected" isn't the same as "verified," which is why `CLAUDE.md` says to confirm each via
`debug_log`/DB evidence the first time it's actually used.

## Trying to automate the status item's single/double-click-right-half gesture

With ordinary menu-item clicks proven reliable, the obvious next target was
`04-lock-and-pause-on-lock-checklist.md`'s Scenario B -- the status icon's
right-half single-click (pause/resume toggle) and double-click (lock request) gesture, which is
its own distinct code path from the menu item and specifically exists to confirm the gesture is a
genuine equivalent, not just wired to open the menu. Reading `MenuBarController
.handleStatusItemClick` showed why the menu-click approach couldn't reach it: the app decides
left-half vs. right-half by checking `event.locationInWindow` converted to button-local
coordinates against `button.bounds.width / 2`, using the *actual pixel position* of a real
`NSEvent`. A `click` on the status item's accessibility element (the mechanism that works for
ordinary menu-opening) is an AXPress action, not a positioned mouse event -- it doesn't carry real
screen coordinates the way a synthesized native click does, so it can't land specifically in the
right half.

The natural next attempt was `tell application "System Events" to click at {x, y}`, which *does*
simulate a real, positioned mouse click at absolute screen coordinates -- reading the status item's
`position`/`size` via accessibility (`{2172, 3}, {166, 24}` in that session) to compute a point
well inside the right half (`{2300, 15}`). It did not work: after the click, `device_event` showed
no new pause-toggle row and `debug_log` showed nothing related, on a device that was confirmed
unlocked and paused right beforehand (so a working right-half single-click should have resumed it).
A left-half coordinate click was tried too, with similarly inconclusive results -- menu item names
were still readable afterward, but that turned out not to be meaningful evidence either way, since
`System Events` can apparently introspect an `NSStatusItem`'s attached `NSMenu` structure
independent of whether any click actually opened it.

Given an ambiguous, non-working result and no further obvious mechanism to try (menu-bar status
items may simply not be hit-testable via screen-coordinate clicks the way ordinary window content
is -- they live in a different window layer), this was left as a documented negative result rather
than chased further: the gesture stays `(You)` in `Tests/Interactive/`, and `CLAUDE.md` says so
plainly so a future session doesn't spend time re-attempting the identical approach.

## Splitting 04's scenarios between Bench and Interactive

Once menu clicks were verified and the right-half gesture verified *not* automatable (previous
section), `04-lock-and-pause-on-lock-checklist.md` -- originally five scenarios (A-E), entirely in
`Tests/Interactive/` -- needed sorting scenario-by-scenario rather than treated as one atomic unit.
Checking each for an irreducible human-only step (the right-half gesture, a physical flip, or the
time-increasing check):

- **Scenario A** (menu Lock/Unlock) and **B** (double-click gesture) each still contain the
  right-half single-click check and/or a physical flip-while-locked check -- not fully convertible,
  stayed in Interactive, with everything *else* inside them (the menu clicks, the screenshot/log
  confirmations) converted anyway.
- **Scenario C** (Lock pauses when `pause_on_lock` is on) and **D** (Quit pauses+locks) turned out
  to use *only* menu-item clicks throughout -- no gesture, no physical action anywhere in either.
  Fully convertible, moved to `Tests/Bench/`, renamed to Bench's own Scenario A/B for clean,
  consecutive lettering within that file (rather than Bench holding "C" and "D" while Interactive
  holds "A", "B", "E" -- confusing without the original single-file context).
- **Scenario E** (quit does nothing extra when `pause_on_lock` is off) turned out to be almost
  entirely the same *kind* of mechanics as D -- restore a setting, quit, confirm a `debug_log`
  sequence, restart, confirm clean state -- all of which is now covered by the tail end of Bench's
  new Scenario B. Duplicating that in Interactive too would just be redundant. What's left that's
  actually unique to E is the "is the time increasing?" observation, which stayed as a new, much
  shorter Interactive Scenario C, explicitly picking up from the clean state Bench's Scenario B
  leaves rather than re-deriving it.

Setup moved to Bench too, since it's what C/D (now Bench A/B) need to start from, and since Bench
always runs before Interactive in the same overall session, Interactive's Scenario A/B can safely
assume Bench already established a clean baseline -- consistent with how `01`/`02`/`03`/`05`'s
Interactive files already say "assumes the state the bench run left."

## "Is the time increasing?" doesn't have to mean asking a human

The first pass at splitting 04 (previous section) left its final scenario's "is the time
increasing?" check as `(You)`, reasoning by analogy from the "Presenting durations" guidance
elsewhere in `CLAUDE.md` -- which is about how to *phrase* a question when a human genuinely has to
watch the menu bar, not a blanket rule that every time-based fact needs a human. That was too broad
a generalization. The actual fact being checked -- is the device currently running, not paused --
already has a direct DB proxy: the same still-open `device_event` row's `duration_seconds` is
computed live from `start_epoch`, so noting it, waiting a few seconds, and re-querying the same row
proves the same thing a human watching the menu bar would, without needing eyes on the screen at
all -- exactly the technique `02-history-refresh-checklist.md`'s Bench Scenario A already used for
a different purpose (confirming a *skip-path* refresh). Once converted, that scenario had zero
remaining `(You)` steps and moved to Bench too, as Scenario C.

The general principle this exposed: a single frozen screenshot can't show change over time, but
that doesn't mean the *fact* itself needs a human -- prefer a DB-based proxy when one exists (as
here), and when there truly isn't one (confirming the *rendering itself*, not just the underlying
data), two or more screenshots taken more than a second apart can serve the same purpose a human
would. For a single element, two screenshots showing different states is enough to prove it's
changing. For *multiple* elements that must change in lockstep with each other (the actual
remaining case in `03-battery-low-indicator-checklist.md`), two screenshots aren't enough --
both could show "changed" despite having flipped at different moments within the gap -- that needs
several samples spaced closely relative to the blink interval, comparing all elements at each one.
This hasn't actually been done yet for `03` -- doing so is a real, separate task (verify the
approach live, then convert and update `CLAUDE.md`'s entry), not something to assume works just
because the reasoning sounds right, consistent with every other capability in this file.

## Why the destructive Reset Device click stays a deliberate pause-point

Once Accessibility-driven clicking was proven to work in general, it became technically possible to
also drive the Reset Device button and its destructive-action confirmation dialog in
`01-reset-device-checklist.md` -- and briefly tempting to just convert that step to fully
unattended `(Claude)`, like everything else in Bench.

That was deliberately not done. A factory reset erases the physical device's facet colors, task
settings, name, and password, and cannot be undone -- a meaningfully bigger and more consequential
action than a database mutation in `test.sqlite`, even though the *mechanism* for triggering it
(a scripted click) is now identical to clicking a checkbox. The resolution: keep it in Bench as a
step Claude performs, but with explicit instruction baked into the checklist text to pause and get
the user's real-time, explicit go-ahead immediately before that specific click, every single time
the checklist runs -- treating "needs a human's authorization" as a distinct reason to slow down
from "needs a human's hands," even once the hands are no longer strictly required.

## Screenshot-based confirmation predates the Accessibility fix, and still has a role

Before Accessibility was working at all, the only way to confirm a static visual element (a lock
badge, a menu item's text) without asking the user was `screencapture` plus visual inspection of
the resulting image -- which is what "Screenshot-based visual confirmation" in `CLAUDE.md`
describes, and what `04-lock-and-pause-on-lock-checklist.md` was converted to use, item by item,
before Accessibility-based text reads were available.

That conversion required its own mid-session correction: a first attempt at driving Preferences to
a specific tab, for screenshot purposes, used a debug env-var hook (`TF_DEBUG_OPEN_SETTINGS`) read
in `applicationDidFinishLaunching` -- but a real bug surfaced along the way. `SettingsRootView`'s
`selectedTab` is a plain `@State` defaulting to `.facets`, and the `.onChange(of:
appState.pendingSettingsTab)` modifier that's supposed to jump it to a specific tab does not fire on
the very first mount if `pendingSettingsTab` was already set to that value *before* the view was
created (SwiftUI's `onChange` only fires on a transition, not an already-true initial value). So the
very first time Preferences is ever opened in a fresh app launch via `openPreferences()` (which sets
`pendingSettingsTab` then calls `show()`), it can silently open on the wrong tab. This was a real,
pre-existing latent bug discovered as a side effect of testing, not something introduced by the
testing -- it was not fixed as part of this work (out of scope at the time) and is worth knowing
about if a future checklist run behaves as if `pendingSettingsTab` didn't take effect.

Given the debug-hook approach hit this same bug, verification switched to temporarily hardcoding
`selectedTab`'s default for the one test session, confirmed the sizing fix, then reverted the
temporary change immediately afterward -- consistent with the root `CLAUDE.md` rule that temporary
debug scaffolding used purely to drive a verification must never ship as part of the actual change.

Now that Accessibility-based tab-switching and text-reading are verified working, screenshots are
only actually necessary for the narrower "custom-drawn image, or color/animation" case described
above -- but the technique remains documented and in active use in
`04-lock-and-pause-on-lock-checklist.md` and elsewhere for exactly that case.

## The first live-testing incident, and the heads-up/all-clear rule it produced

Early in this work, before any of the mechanics above were established, a live screenshot-based
verification session was run without warning the user first. The user was still at the keyboard
while the app's Preferences window had real focus, and a keystroke of theirs landed in the app
instead of wherever they intended it. That's what produced the root `CLAUDE.md` rule requiring a
big, hard-to-miss heads-up and explicit wait-for-acknowledgment before launching the app for any
interactive/visual verification, and an equally prominent all-clear once it's safe to use the
keyboard/mouse again -- both of which this `Tests/` work has followed ever since, including for
every Accessibility-driven verification described above, even though scripted UI actions themselves
don't consume the user's actual keyboard/mouse input queue (the risk is the target app taking real
focus, not the scripting mechanism).
