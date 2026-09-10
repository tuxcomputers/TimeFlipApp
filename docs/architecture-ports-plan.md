# Making the circle-and-square model real

The rule is in `CLAUDE.md` under *The core is platform-blind, and every platform capability is a port*.
The picture is [`architecture-model.svg`](architecture-model.svg). This is the list of work that turns
the two into the code.

**Scope, as set on 2026-09-10.** macOS only. Windows is not in scope. Linux code found in the core gets
**moved but not altered**, and the Linux port resumes once the Mac matches the model. `swift test` is the
only suite running; the scripted suite is set aside.

## How an item is finished

The diagram's three greens are the definition of done, and they are three different moments:

1. **The arm** goes green once the port exists in `FacetCore` and something is handed over it.
2. **The slot** goes green once that one platform's adapter sits in the square and `main.swift` hands it over.
3. **The square** goes green only once *every* platform's adapter is done, so it stays black through all of this.

Only 1 and 2 are in scope. A section here is ticked when its arm is green and the macOS slot is green.

Each item also has to pass the test that separates a port from noise: **would a third platform need a
different implementation, or merely a different import?** Different implementation is a port. Different
import is a shim and may stay in the core.

## The order, and why it is this order

The cheap and the blocking come first, the large and the discretionary last.

| # | Arm | State | Why here |
|---|-----|-------|----------|
| 0 | Housekeeping | **done** | Corrections that cost nothing and were noise in every scan. |
| 1 | The clock | **done** | Six core modules on `RunLoop.main`, which `FacetLinux` never runs. A live latent fault. |
| 3 | Starting and stopping | **done** | Landed with `QuitSequence`. Turned out to need no protocol at all: see its section. |
| 2 | Files and folders | **not a port** | Reordered down on 2026-09-10. Corelibs already answers it per platform, measured on Linux hardware. See its section. |
| 4 | Menu bar | in progress | The **second adapter already exists** and is the right shape. A real seam with one outlier, not a hypothetical one. |
| 5 | Radio | after | The biggest port with a protocol already standing. Wants `feature/commandChannel` landed first. |
| 6 | Windows and dialogs | after | 3,536 lines and the least mechanical work in the app. Everything above teaches something it needs. |
| 7 | Storage | deferred | One adapter, and the decision behind it is unsettled. |

Reorder this table as the work teaches something. An item that turns out to block another moves above it,
and the move gets a line saying what was discovered.

**Two moved on 2026-09-10, both downwards, and both because the grep that put them there was a worse
source than the repo's own record.** Items 2 and 3 were sized from scanning `Sources/FacetCore` for platform
symbols. `docs/linux-port.md` had already answered one of them from a real Linux machine, and the other
turned out to want no port at all. The lesson is cheap to state and was not free to learn: **read
`docs/linux-port.md` before sizing an arm**, because the port that has already been measured is the one
least likely to show up in a grep.

---

## 0. Housekeeping

- [x] Delete `Sources/FacetApp/`. Referenced by no target, left behind by the rename `Package.swift:284`
      describes. **It was not empty**: it held an untracked `google-client.json`, byte-identical to the live
      one in `FacetCore/Resources`, which is the copy `GoogleCredentials` actually reads. Removed after
      checking the hashes matched.
- [x] Move `GoogleOAuthClient` into the core. Its only tie to AppKit was **one default argument**,
      `open: (URL) -> Void = { NSWorkspace.shared.open($0) }`. The default is gone, so a caller has to
      supply the browser, and 113 lines of PKCE, redirect handling and token exchange are now core.
      `Package.swift:213` corrected: it named `GoogleOAuthClient` as the reader of `google-client.json`,
      but the reader is `GoogleCredentials`, which is core and reads it from `FacetCore/Resources`.
- [x] Record the `CryptoKit` judgement. `GoogleOAuthRules` picks CryptoKit or `PortableSHA256` behind a
      `#if`, and the allowlist calls it a shim. Both compute SHA-256, so the *answer* cannot differ, but
      they are two implementations rather than two spellings of one. It is either a shim by outcome or a
      port by the letter of the test. **Settled as a shim, by a better argument than either**: the `#else`
      branch is `PortableSHA256`, which is platform-free and already written and already tested on Darwin
      against CryptoKit's own answer, so a third platform needs *nothing*. The `#if` is an opt-in to Apple's
      implementation on one platform rather than a gap filled per platform. Written into the allowlist.

## 1. The clock

**The port.** `Scheduler`: wake me in N seconds, once or repeating, and here is the handle to stop it.
`RunLoopScheduler` is the macOS slot, `HandDrivenScheduler` the test slot.

**Nothing asks what time it is**, which the first draft of this plan had wrong. `Date()` is the same Foundation
on every platform, so it is not a capability the platform provides and not a port. What the platform provides is
the *waiting*.

**Why first.** Six core modules build a `Timer` and add it to `RunLoop.main`: `DailyLimitWatch`,
`DeviceReconnector`, `LowBatteryWatch`, `HistoryTimer`, `QuitSequence`, `WriteDebounce`. `FacetLinux` never
runs `RunLoop.main`, so on Linux **not one of those timers will ever fire**. That is a production fault
sitting in the core today, and it is the clearest case in the codebase of the core caring what platform it
is on while insisting it does not.

**Half the seam exists already.** `HistoryTimer.fire()`, `LowBatteryWatch.fire()` and `WriteDebounce.fire()`
are internal so a test can take the place of the run loop. That is the port in embryo: the decision is
already separated from the thing that schedules it. Three modules do not have it.

- [x] Name the port and put it in the core, with the hand-driven adapter the tests already want.
- [x] `WriteDebounce` first: smallest, one timer, `fire()` already there.
- [x] `HistoryTimer` and `LowBatteryWatch`: same shape, `fire()` already there. `HistoryTimer`'s hand-set
      `Timer.tolerance` became `mayGroup` on the port: permission rather than a number, because the core knows
      whether a wake must land on the second and the platform knows what to do about it. Its `TimerHolder` went
      too, and what that bought is written onto the property that replaced it.
- [x] `DailyLimitWatch`: needed no `fire()` in the end, the port being the seam. **`start`, `stop` and
      `resumeIfStopped` had no coverage at all** before this, including the guard run 116 paid for on
      2026-08-27; all three are tested now and that regression fails in a tenth of a second.
- [x] `DeviceReconnector`: the backoff *walk* is now testable, where only the pure
      `DeviceReconnectRules.delay(afterFailures:)` was before. One test that said "nothing to assert but that it
      survives and schedules" can now assert that it schedules.
- [x] `QuitSequence`: the five second deadline. Its test **spent six real seconds** waiting on a real timer
      with a five second grace on top; it is now a `tick()`, and the XCTest run dropped from 20.0s to 13.9s.
- [x] The macOS adapter in `FacetMac`, injected from `main.swift`. One instance, because there is one run loop.
- [x] Widen `PlatformBlindCoreTests` to fail on `RunLoop` in the core, now that nothing needs it. It is a
      second check, `theCoreUsesItsPorts`, scanning non-comment lines against a list of banned spellings.
      `Timer.scheduledTimer` is on it beside `RunLoop`, because it adds to a run loop **without naming one** and
      would have walked straight past a check that only looked for the first.

## 2. Files and folders

**Not a port, and this section is the argument rather than a deferral.** It was second on this list when the
list was written, sized by grepping the core for `applicationSupportDirectory`, `Bundle.main` and `flock`. The
repo had already answered it.

**The data directory answers itself on both platforms.** `docs/linux-port.md` records it measured on a real
Linux machine on 2026-09-08: `.applicationSupportDirectory` resolves to `/home/harry/.local/share`, so the
app's own path comes out as `~/.local/share/Facet/appdata.sqlite`, and the note says **"No code change:
corelibs does the XDG layout"**. `DebugTraceRules.defaultDirectory` computes from it rather than writing a path
down, which is why it is right on either platform. One implementation, correct answers on both, needing neither
a different implementation nor a different import: that is not a port by the test in `CLAUDE.md`, and wrapping
it in one would buy nothing and cost four call sites.

**The instance lock works on Linux too, and that was measured on the same day.** Two real processes: the first
claimed it, the second was refused `heldByAnotherInstance`, and `~/.local/share/Facet/singleinstance.lock` was
created on the way. `flock` is POSIX. It is Windows that has no `flock`, and Windows is not in scope, so
`InstanceLock` is a port **for a platform nobody is writing yet**. It stays where it is until somebody is.

**`Bundle.main` is a fallback chain, not a platform choice.** Every use pairs it with `Bundle.module`, which
SwiftPM generates on both platforms, or with a literal default. On Linux the first probe finds nothing and the
second answers, so a third platform needs no new implementation. The one thing worth carrying forward is a
*degradation* rather than a fault: `Bundle.main.bundleIdentifier` is nil off a `.app`, so `DevicePINStore` and
`GoogleTokenStore` both fall back to the same literal service name, and the keying that stops a developer build
and a release build fighting over one keyring item does not separate them there.

- [x] Establish whether this is a port at all. **It is not**, on the evidence above.
- [ ] The bundle-identifier degradation on Linux: a real gap, but it belongs to whoever writes the Linux
      keyring adapter, and it is a value the composition root should supply rather than a port.
- [ ] `Facet_FacetCore.resources` must ship beside the executable or a Linux binary dies with a `fatalError`
      before `DatabaseBootstrap.Failure.ddlDirectoryNotFound` can report anything (`docs/linux-port.md`). That
      is a packaging rule for `docs/distribution.md`, not an arm on this diagram.

## 3. Starting and stopping

**Done, and it needed no protocol.** `QuitSequence` moved into the core on 2026-09-10 and `QuitDelegate` is the
macOS adapter, holding the `NSApplicationDelegate` conformance, the terminate reply derived from what
`pauseAndLockTheCube` reported, and nothing else.

**What made this cheaper than the diagram suggests is the direction of the call.** Every other arm is the core
reaching out, which needs a protocol so that what it reaches for can be swapped. This one is the platform
reaching *in*: AppKit asks `applicationShouldTerminate`, GTK's Quit item calls `MenuBar.quit`, and both then run
the same core sequence. Nothing in the core has to name the thing calling it, so there is nothing to abstract.
The one place the core does want to *cause* a stop, `DeviceReconnector`, already takes it as an injected closure
and says why: "Injected rather than calling `NSApp` here".

- [x] Establish what the port is. It is a callback direction, not an interface.
- [x] `QuitSequence` in the core, `QuitDelegate` in `FacetMac`, `app.run()` in the composition root where a
      platform-specific launch belongs.
- [x] `QuitSequence`'s deadline moved with item 1.
- [ ] Prose only: `QuitSequence`'s doc comments still explain themselves in terms of `NSApp` and
      `applicationShouldTerminate`. The reasoning is measured and worth keeping; some of it now describes
      `QuitDelegate` and should sit there. Tidy when item 6 is in that area anyway.

## 4. Menu bar

**The port.** A title, a menu, a click and which side it was.

**Why here, and why it is the most instructive one.** `Sources/FacetLinux/MenuBar.swift` is 191 lines of
GTK that decides nothing: it takes closures and reads them, and knows nothing about a category.
`MenuBarController` is 683 lines and is not that shape. So this is a **real seam with two adapters**
already, where one of them is right, which makes it the only port on this list with a worked example
sitting in the repo.

`CLAUDE.md` already says to point at the Linux one when in doubt.

- [x] Read `MenuBarController` against `FacetLinux/MenuBar.swift` and mark every line that decides something.
- [x] **The dropdown.** `StatusItemMenu` in the core decides which lines there are, what each says, whether it
      can be chosen and what choosing it does. `MenuBarController` renders them into `NSMenu` and decides
      nothing; the Linux indicator can render the same answers, its `Item` already being this shape. 683 lines
      down to 630 (the commit message for this says 596, which was written before it was counted). `CubeReading` moved into the core with it, being three core states and no platform anything.
- [x] The identifiers move too, so a check addressing the dropdown reads the same string on either platform,
      through `AXIdentifier` on a Mac and `com.canonical.dbusmenu`'s `GetLayout` on Linux.
- [ ] **The title.** `redraw` still holds the tick decision, the has-it-changed comparison and the two rules
      about which `debug_log` rows to write. `StatusItemTitle` is already core; these are what sit around it.
- [ ] **The click.** `handleClick` already asks `StatusItemClickRouter`; what is left is reading the event and
      the `DispatchWorkItem` that holds a cube pause back for `NSEvent.doubleClickInterval`.

## 5. Radio

**The port.** Connect, read, write, subscribe.

`CubeRadio` already stands in the core. Behind it, `BluetoothRadio` (1,418) and `DeviceLogin` (1,482) are
2,900 lines of CoreBluetooth, and a good deal of what is in there is protocol reasoning rather than
CoreBluetooth: the command channel, the read-back matrix, the queue.

**Land `feature/commandChannel` first.** It holds candidate 1's command-channel cluster, is confirmed on
the cube, and is eight or more commits behind. Every hour it stays unmerged is an hour this section
conflicts with.

- [ ] Land `feature/commandChannel`.
- [ ] Take the command channel, the read-back matching and the queue into the core.
- [ ] Leave CoreBluetooth, the delegate methods and the UUID mapping in `FacetMac`.
- [ ] Check `CubeRadio` still says what the core needs and no more.

## 6. Windows and dialogs

**The port.** What to show, and which answer came back.

`SettingsWindowController` is 3,536 lines, the largest file in the app. There are 19 `NSAlert` sites, 18 of
them in that file. `CategoryRenameRules.choice(forButtonIndex:)` takes an **AppKit button index**, which is
the core reaching through the arm rather than along it.

This is last of the real work because it is the least mechanical and because items 1 to 4 all teach
something it needs.

- [ ] The dialog port: a question, its answers, and which came back, with no button indices in it.
- [ ] `CategoryRenameRules.choice(forButtonIndex:)` off AppKit indices.
- [ ] The 19 alert sites onto the port.
- [ ] Then the panes, which is its own list once the alerts are out of the way.

## 7. Storage

**Deferred, and this is the reasoning rather than a delay.**

The owner has settled that storage is SQLite on all three platforms, and that a remote server, when it
comes, is an adapter. So today there is **one adapter and no second**, which by the codebase-design rule is
a hypothetical seam rather than a real one. The stores already sit in the core and `sqlite3` is the same
library everywhere: a different import at worst, not a different implementation.

There is also an open decision in the way, recorded in `CLAUDE.md`: the first design rule says read from
the database every time a value is needed, which is right for a local file and is a network round trip per
question over an API. That has to be settled before a non-SQLite adapter is written, and settled in
`CLAUDE.md` rather than inside whoever writes it.

- [ ] Nothing, until either the remote adapter is real or an in-memory test adapter earns its keep.

---

## Discovered along the way

Things found while doing the work that the diagram or the plan did not have. Each one either becomes an
item above or gets a reason for not being one.

- **A ninth arm: opening a URL.** The diagram has eight. `NSWorkspace.shared.open` in `GoogleOAuthClient`
  and `NSWorkspace.shared.activateFileViewerSelecting` at `SettingsWindowController:1650` are a platform
  capability with no arm on the picture: hand the user's desktop a URL or a file and let it decide. Two
  sites, both macOS, `xdg-open` on Linux. **Half done as of item 0**: `GoogleSignIn.run(open:)` is the arm
  and the sign-in call site is the macOS slot. The other site, "show the trace in Finder", is Mac-only UI
  and stays where it is until item 6. The diagram still needs the arm drawn.
