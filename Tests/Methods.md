# Methods

Reusable techniques for checking this app against a running copy of itself. A checklist step says
`Method: N` and points here rather than repeating the mechanics.

**Numbers are permanent.** Once a checklist cites one, renumbering silently repoints that step at
another method, which is the same class of fault as addressing a tab by index -- the step goes on
passing while testing something else. A new method takes the next unused number and goes at the end,
however tidy it would be to slot it in beside a related one.

Everything here has been done, not guessed. When you discover something new, add the fact and the
command, not the story of finding it. Keep entries short: a rule buried in prose is a rule nobody
follows.

The suite these serve is being rebuilt from scratch, per the device-test section of the root
`CLAUDE.md`. The previous suite's methods are in `Archive/Tests/Methods.md`; its locators address the
old app's accessibility tree and do not apply, but its **device measurements** still do, because they
are facts about the hardware.

<a id="method-1"></a>
## Method 1: Build and bundle

`swift build` compiles; it does not make something launchable. Accessibility ignores a bare executable
-- no status item appears in the tree at all -- so anything driven by a script has to be bundled:

```sh
swift build && mint run stackotter/swift-bundler@main bundle Facet
open .build/bundler/apps/Facet/Facet.app
```

**`scripts/run.sh` builds; `open`ing the `.app` does not.** The script ends in `swift-bundler run`, which builds and
bundles before it launches (`--skip-build` exists to opt out), so a run after an edit always carries the edit. The two
lines above are the dangerous shape: `open` launches whatever was bundled last, however old.

This has already cost an hour. A fix was confirmed correct in the source at 21:51:49 and tested against a binary
built at 21:47:55, and the feature "still did not work" because the running app predated it. Nothing about a running
app announces its age, so when driving a verification, **either go through `scripts/run.sh` or check the timestamp**:

```sh
stat -f '%Sm' .build/bundler/apps/Facet/Facet.app/Contents/MacOS/Facet
```

<a id="method-2"></a>
## URL.appendingPathComponent escapes what you give it

`appendingPathComponent` percent-encodes its argument. Handing it a string that is already escaped escapes it
twice, and `%40` becomes `%2540`:

```swift
// wrong: abc%2540group%252Ecalendar%252Egoogle%252Ecom
URL(string: "https://www.googleapis.com/calendar/v3/calendars")!
    .appendingPathComponent(id.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!)

// right: abc%40group.calendar.google.com
URL(string: endpoint.absoluteString + "/" + id.addingPercentEncoding(withAllowedCharacters: allowed)!)
```

Measured 2026-08-15 against a real Google account. It cost a calendar: the double-escaped id addressed nothing,
Google answered 404, and the app treats a 404 as "this calendar has been deleted" and forgot it. **A wrong URL and a
deleted resource are the same status code**, so anything that acts on a 404 needs its URL asserted character by
character in a test, not merely checked for the right prefix. The test that passed before this bug asserted the
prefix and the absence of "@", and both were true of the broken URL.

## Method 2: Press anything by name

```sh
scripts/ax-press.py create-category          # by AXIdentifier
scripts/ax-press.py --desc Faces             # by AXDescription, for elements that cannot carry one
```

Searched for anywhere in the tree rather than pathed to. A path like `button 1 of group 1 of group 1 of
window "Facet Settings"` breaks the moment a container is added between them, and breaks by finding
the wrong element rather than nothing.

Two kinds of element cannot carry an identifier and are matched on their label with `--desc`: the
Settings tab buttons (`NSTabViewItem.identifier` never reaches `AXIdentifier`, and the item has no
`setAccessibilityIdentifier` at all; a segmented control has no per-segment identifier either), and
anything AppKit draws for itself, like a window's traffic lights.

Exits non-zero when nothing matches, so a missing element is distinguishable from a click that did
nothing.

<a id="method-3"></a>
## Method 3: Open the status item's menu

```sh
scripts/status-item-click.py            # left half: opens the menu
scripts/status-item-click.py --right    # right half
```

The **only** gesture that needs a real mouse event: a status item exposes no accessibility action, so
there is nothing to press. Its menu items are ordinary named elements once it is open --
`scripts/ax-press.py open-settings`, `scripts/ax-press.py quit-app` (Method 2) -- and they are absent
from the tree while it is closed, so open it first.

The item's position is read at click time, never remembered: its width follows its title, which becomes
a live duration once something is being timed.

<a id="method-4"></a>
## Method 4: Read the accessibility tree

```sh
scripts/ax-dump.py                 # every window
scripts/ax-dump.py --menu-bar      # the status item, and any menu it has open
scripts/ax-dump.py --frames        # with positions and sizes
```

This is how "is everything named?" gets answered rather than assumed. A status item lives in
`AXExtrasMenuBar`, which is a different attribute from `AXMenuBar` -- an accessory app has none of the
latter, so asking for it alone comes back empty and reads as an app with nothing in the menu bar.

<a id="method-5"></a>
## Method 5: Confirm what the app did, from `debug_log`

Every click the app handles writes a row. Take the high-water mark first, act, then read past it:

```sh
DB=~/Library/Application\ Support/Facet/appdata.sqlite
BASE=$(sqlite3 "$DB" "SELECT MAX(debug_log_id) FROM debug_log;")
# ... do the thing ...
sqlite3 -header -column "$DB" "SELECT logged_at, tag, message FROM debug_log WHERE debug_log_id > $BASE ORDER BY debug_log_id;"
```

Rows, not console text: stdout only reaches a terminal when the app is launched from one, and a row
survives the session either way.

<a id="method-6"></a>
## Method 6: Confirm an appearance by measuring it

Screenshot the region, then sample the pixels rather than trusting an eye on a scaled-down image:

```sh
screencapture -x -R <x>,<y>,<w>,<h> shot.png
```

```python
from AppKit import NSImage
rep = NSImage.alloc().initWithContentsOfFile_("shot.png").representations()[0]
colour = rep.colorAtX_y_(x, y)   # note: the image is 2x on a retina display
```

Worth the trouble when the question is a few points or a shade: an eyeballed "7pt above, 5pt below" was
5 and 5 when measured.

<a id="method-7"></a>
## Method 7: Type into a field without keystrokes

Set the field's `AXValue` instead, then press whatever commits it (Method 2):

```sh
scripts/ax-set.py category-name-field "Admin"
scripts/ax-press.py save-category
```

Confirmed on the Categories tab: the field showed the text and Save wrote `category_id 11`. This is the
way to fill a field, because synthetic keystrokes go wherever focus happens to be and that is not
necessarily the app -- see the note below.

An `NSTextField`'s `action` fires on Return and on losing focus, not on this write, so something still
has to commit it: press the Save button beside it, or move focus.

<a id="method-8"></a>
## Method 8: Hold a button down

Accessibility has no hold: `AXPress` is always a click, so anything that repeats while held needs real
mouse events.

```sh
scripts/ax-hold.py category-limit-1-up 2.0     # down, wait two seconds, up
```

It reads the element's own `AXPosition`/`AXSize` and posts the events there, so the app has to be on
screen and nobody should be touching the mouse while it runs.

Used to confirm the daily-limit arrows accelerate. **Read the result from `debug_log` rather than the
final value**, since the timing is the thing being checked: the rows showed 5 immediately, 6 after
0.403s, then 7, 8, 9, 10 at ~0.104s, then 15, 20, 25 at ~0.304s.

<a id="method-9"></a>
## Method 9: Click a point on screen

For anything that cannot be pressed by name, a popover's contents above all. Screenshot the region, work out
the point, and post real events there:

```python
import Quartz, time, subprocess
from AppKit import NSRunningApplication, NSApplicationActivateIgnoringOtherApps
pid = int(subprocess.check_output(["pgrep", "-x", "Facet"]).split()[0])
NSRunningApplication.runningApplicationWithProcessIdentifier_(pid).activateWithOptions_(
    NSApplicationActivateIgnoringOtherApps)                      # or the click only activates the app
time.sleep(0.4)
def post(kind, x, y):
    e = Quartz.CGEventCreateMouseEvent(None, kind, (x, y), Quartz.kCGMouseButtonLeft)
    Quartz.CGEventSetIntegerValueField(e, Quartz.kCGMouseEventClickState, 1)   # 0 is ignored by AppKit
    Quartz.CGEventPost(Quartz.kCGHIDEventTap, e)
post(Quartz.kCGEventMouseMoved, x, y); time.sleep(0.2)
post(Quartz.kCGEventLeftMouseDown, x, y); time.sleep(0.15)
post(Quartz.kCGEventLeftMouseUp, x, y)
```

`screencapture -R x,y,w,h` takes points and writes a 2x image on a retina display, so a feature at image
`(px, py)` is at `(x + px/2, y + py/2)`. Confirmed against `AXPosition`: they are the same space.

Two things make a click land and do nothing, both silently:

- **The app must be activated first.** A window of an inactive app swallows the first click as activation, and
  `AXPress` does not activate anything -- so a picker opened by a script is showing while every click into it
  is thrown away.
- **`kCGMouseEventClickState` must be set to 1.** Left at 0 the event is posted and the pointer moves, and
  AppKit does not treat it as a click.

<a id="method-10"></a>
## Method 10: Commit an inline edit

Setting a field's `AXValue` fills it but commits nothing ([Method 7](#method-7)). Where the commit is Return rather
than a button -- the Categories tab's rename -- post the key, having activated the app first:

```python
for down in (True, False):
    Quartz.CGEventPost(Quartz.kCGHIDEventTap, Quartz.CGEventCreateKeyboardEvent(None, 36, down))  # 36 = Return
```

One of the few places a synthetic keystroke is right: the field being typed into holds focus, so there is nowhere
else for the key to land. **Escape is still never posted** -- it reaches whatever has focus and the session driving
the app is often what that is.

Confirmed on the rename: `ax-press.py category-name-11`, `ax-set.py category-name-11-field "Admin work"`, Return,
then the sheet's own buttons are ordinary named elements (`action-button-1` is the first one added).

## Notes that have cost time

- **A popover is invisible to accessibility.** The icon picker and the colour list are not in the app's
  `AXWindows`, not in its `AXChildren`, and not under the window that opened them, so `ax-dump.py` shows nothing
  and `ax-press.py` cannot press a cell by name. Click them by position ([Method 9](#method-9)). The click that
  *opens* one is an ordinary named press.

- **A button behind a label is never pressed.** A click on an `NSTextField` label goes up the responder chain to
  the label's own *superview*, so a borderless button sitting behind it as a **sibling** gets nothing. The row or
  heading has to **be** the button, with the label and any swatch as its own subviews (`CategoryRowView`,
  `ColourListRow`, `CategorySection`). This is invisible from a screenshot and from the accessibility tree, and
  `swift test` cannot see it either -- `performClick` presses the button directly, so a test passes on a control
  no mouse can reach. It shipped once: the Categories headings drew correctly and folded when the space *after*
  the words was clicked, while a click on "Inactive" itself did nothing at all. **Check a click target by
  clicking it on screen and reading `debug_log`.** A knock-on effect worth expecting: a label inside a button
  stops appearing in `ax-dump.py` as an element of its own, the button absorbing it, so match the button.

- **Three more ways a layout is wrong with every constraint satisfied**, all found on the Report tab and all invisible
  to `swift test`: an `NSStackView` given more height than its views need **spreads the slack between them** (a
  calendar's three rows ended up 147pt apart, fixed by pinning three subviews with constants instead); a view added
  with `addSubview` rather than a stack's `addView` **keeps its autoresizing frame**, so Auto Layout pins it to the
  zero frame it was built with (a 0-by-0 grid with correct constraints above it); and an inequality left anywhere in a
  vertical chain is the one link that stretches when something below pulls (`monthHeader` pinned "at least as tall as
  its arrows"). If a layout can be satisfied at more than one size, it will eventually be satisfied at the wrong one.

- **A scroll view's document view hangs at the bottom unless it is flipped.** AppKit measures an ordinary view from its
  bottom edge, so a list shorter than the space it scrolls in sits at the bottom of it. `ReportTotalsList` puts the
  rows in a `FlippedView`.

- **A view pinned top *and* bottom can be stretched, and nothing fails when it is.** The Report tab's calendars were
  pinned to both edges of the row holding them, and a calendar's height is decided from the inside, so the whole chain
  became elastic: the row filled the tab, the box filled the row, and the stack inside spread its three rows 147pt
  apart. The constraints were satisfiable, so there was no broken-constraint log and `swift test` was green. Pin one
  edge and let the content decide the other. **`ax-dump.py --frames` is how this was found** -- a box 564pt tall where
  327pt was expected is obvious in the frames and invisible in the tree.

- **A hidden view keeps its height.** Auto Layout ignores `isHidden`; only an `NSStackView` collapses a hidden
  *arranged* subview. So folding a section by hiding its list leaves the list's full height behind, which shows up
  as blank space rather than as a fault. `CategorySection` swaps the constraint pinning its bottom edge instead.
  Measure a fold by the section's own `frame.height`, open against shut, not by `isHidden`.

- **Never post Escape (key code 53) while driving this app.** It reaches whatever has focus, and if that
  is not the app it interrupts the session driving it. There is nothing in this app that needs it: the
  Settings window closes with `ax-press.py close-settings`, and menus close by pressing an item.
- **Synthetic keystrokes are a last resort generally.** They go wherever focus is, which is not
  necessarily the app; a named press cannot miss.
- **`open` on an already-running app activates it; it does not launch the new build.** So the change under
  test is not the code being driven, and the single-instance lock means a genuinely new process would
  stand down anyway. `pgrep -x Facet` before every launch, and quit what is there first. This cost a
  wrong diagnosis: a new quit step looked broken when the running copy simply predated it.
- **A menu item pressed while its menu is closed reports success and does nothing.**
  `scripts/ax-press.py toggle-pause` exits 0 with `pressed toggle-pause` and the app is unchanged.
  Open the menu first ([Method 3](#method-3)), or press the on-screen control instead
  (`timing-play-pause`). Check the effect, never the exit code.
- **The app writes to whichever database `appdata.sqlite` points at.** Check `db_type` before trusting a
  session with real data: `sqlite3 "$DB" "SELECT setting_value FROM setting WHERE setting_name='db_type';"`,
  and the menu bar's own badge says which one it opened.
- **Switching database keeps it; `-clean` is what empties it.**
  ```bash
  scripts/switch-database.sh test          # -> test.sqlite, exactly as it was left
  scripts/switch-database.sh test -clean   # -> a new test.sqlite, seeded from database/*.sql
  scripts/switch-database.sh prod          # -> production.sqlite (never rebuilt; -clean is refused)
  ```
  Quit and relaunch afterwards: the running app already has the old file open.

## Notes for the hermetic suite (`swift test`)

- **A window built in code is released when it is closed**, so a test that closes one over-releases it and the whole
  run dies with a signal 11 in the autorelease pool drain, naming no test. `OffscreenWindow.host` sets
  `isReleasedWhenClosed = false` for that reason, and closing the window is worth doing: it is what takes focus off a
  field being edited.

- **`performClick` needs a window.** Without one it does nothing at all, silently -- so a click test
  passes or fails on whether some *other* test in the run happened to make a window first. Host the view
  with `OffscreenWindow.host(_:)`.
- **`performClick` also needs a size.** A cell with a zero frame ignores it, and showing a hidden control
  only unhides it: the size arrives with the next layout pass. Call `layoutSubtreeIfNeeded()` before
  clicking, which on screen has always already happened.
- **Layout is testable without a window.** Set a frame, call `layoutSubtreeIfNeeded()`, and assert the
  frames -- see `FacesPaneTests`. A missing or fighting constraint fails nothing on its own; it just
  produces a size nobody chose.
- **`frame` is in the superview's space, so two views at different depths cannot be compared directly.**
  Convert first: `view.convert(view.bounds, to: commonAncestor)`. A comparison across two spaces does not
  error, it just fails oddly -- a control 279pt up the pane read as *below* a list whose own frame said 0,
  because that 0 was measured inside the section view it sits in. Cost a hunt for a layout bug that was
  not there.
- **An `NSMenuItem`'s `target` and an `NSMenu`'s `delegate` are both weak.** A controller nothing retains
  is deallocated the moment it is built, and then choosing an item reaches nobody and the menu updates
  nothing -- silently, so every such test passes or fails on what else the run happens to keep alive. Hold
  the controller for the length of the test (`MenuBarControllerTests`). In the app, `main.swift` holding it
  is what makes it work, which is why `MenuBarController` takes its status item out of the menu bar when it
  dies: an icon that vanishes says something, an icon that sits there dead does not.
- **`NSApp` is nil in a test bundle** until an application object has been made, and it is implicitly
  unwrapped -- so reading it crashes the whole run rather than failing one case. Use
  `NSApplication.shared`, which makes one.
- **`swift test` walks up for `Package.swift`.** Run from `Archive/`, which has none, it still builds and
  tests the rebuilt app -- so a stray `cd` looks like the archive passing 179 tests. Check `pwd` before
  reading anything into a result.
- **A `@MainActor` class cannot touch its own non-Sendable properties in `deinit`.** It is a compile
  error, not a subtlety. Put the handle in a small unisolated object whose own `deinit` does the cleanup --
  `DebugLog`, `DatabaseConnection` and `MenuBarController` all do this, and it is the only way to close an
  sqlite handle or remove a status item at the right moment.
