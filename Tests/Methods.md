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
swift build && mint run stackotter/swift-bundler@main bundle TimeFlip
open .build/bundler/apps/TimeFlip/TimeFlip.app
```

<a id="method-2"></a>
## Method 2: Press anything by name

```sh
scripts/ax-press.py create-category          # by AXIdentifier
scripts/ax-press.py --desc Faces             # by AXDescription, for elements that cannot carry one
```

Searched for anywhere in the tree rather than pathed to. A path like `button 1 of group 1 of group 1 of
window "TimeFlip Settings"` breaks the moment a container is added between them, and breaks by finding
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
DB=~/Library/Application\ Support/TimeFlip/appdata.sqlite
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

## Notes that have cost time

- **Never post Escape (key code 53) while driving this app.** It reaches whatever has focus, and if that
  is not the app it interrupts the session driving it. There is nothing in this app that needs it: the
  Settings window closes with `ax-press.py close-settings`, and menus close by pressing an item.
- **Synthetic keystrokes are a last resort generally.** They go wherever focus is, which is not
  necessarily the app; a named press cannot miss.
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

- **`performClick` needs a window.** Without one it does nothing at all, silently -- so a click test
  passes or fails on whether some *other* test in the run happened to make a window first. Host the view
  with `OffscreenWindow.host(_:)`.
- **`performClick` also needs a size.** A cell with a zero frame ignores it, and showing a hidden control
  only unhides it: the size arrives with the next layout pass. Call `layoutSubtreeIfNeeded()` before
  clicking, which on screen has always already happened.
- **Layout is testable without a window.** Set a frame, call `layoutSubtreeIfNeeded()`, and assert the
  frames -- see `FacesPaneTests`. A missing or fighting constraint fails nothing on its own; it just
  produces a size nobody chose.
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
