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
| 2 | Files and folders | **not an arm** | Off the diagram on 2026-09-10, like storage: it is in the core and there is nothing to select. |
| 4 | Menu bar | **done** | The **second adapter already exists** and is the right shape. A real seam with one outlier, not a hypothetical one. |
| 5 | Radio | arm green, slot black | The biggest port with a protocol already standing. Wants `feature/commandChannel` landed first. |
| 6 | Windows and dialogs | arm green, slot black | 3,536 lines and the least mechanical work in the app. Everything above teaches something it needs. |
| 7 | Storage | **not an arm** | Off the diagram on 2026-09-10. It is in the core and was never a platform capability. |

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

- [x] Establish whether this is a port at all. **It is not**, on the evidence above, and the square has been
      removed from the diagram for the same reason storage was: a capability that is simply in the core is not
      a square, whatever colour it is painted. That retired the grey state, which existed only for this one.
- [x] The one thing that would bring it back, recorded so nobody has to work it out again: **Windows, and only
      half of it.** `flock` does not exist there and the equivalent is a named mutex or `LockFileEx`, which is
      a different implementation and so an arm by this model's own test. The directory half needs nothing even
      then, Foundation mapping it to AppData. Windows is not in scope, and one file is not a square.
- [x] ~~The bundle-identifier degradation on Linux: a real gap, but it belongs to whoever writes the Linux
      keyring adapter, and it is a value the composition root should supply rather than a port.~~
- [x] ~~`Facet_FacetCore.resources` must ship beside the executable or a Linux binary dies with a `fatalError`
      before `DatabaseBootstrap.Failure.ddlDirectoryNotFound` can report anything (`docs/linux-port.md`). That
      is a packaging rule for `docs/distribution.md`, not an arm on this diagram.~~

**Struck through rather than carried**, because neither is an arm and leaving them open here would make this
list the place two unrelated jobs go to be forgotten. Both are real and both are recorded where they belong:
the keyring service name with whoever writes the Linux keyring adapter, and the resource directory in
`docs/linux-port.md`, which is what `docs/distribution.md` has to satisfy.

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
- [x] The prose. `QuitSequence` named `NSApp`, `applicationWillTerminate` and `applicationShouldTerminate`
      five times and now names none: it says what the sequence needs (one half may answer late, the other
      must happen whether or not anybody waited) and points at `FacetMac.QuitDelegate` for which platform
      call each hangs off. **Both AppKit passages were already on `QuitDelegate` word for word**, so this
      deleted a duplicate rather than moving one, which is the two-copies hazard in prose form.
- [x] It also still carried `import FacetCore`, in a file that is now part of `FacetCore`.

**Three stale references the remodel itself created, found by sweeping the core for what it names:**

- `CubeCommandChannel` took a `describe` closure "because `BLETrace` is AppKit-side and does not move". It
  moved: `CubeBytes` is core, the injection was ceremony with one caller passing the only implementation,
  and both are gone.
- `CategoryRenameRules` said `SettingsWindowController.rename` sets the key equivalents. It does not; the
  whole point of `Dialogue.wayOut` is that one file does, for all nineteen.
- `StatusColour` pointed at `StatusColour+AppKit.swift`, which is called `StatusColourDrawing.swift`, and
  `GoogleLoopbackListener` still described `GoogleOAuthClient` as tied to AppKit by a default argument that
  is gone. `StatusItemTitle` cited `MenuBarController.statusIndicatorImage`, which is the *archive's*
  member and now reads as this tree's, so it says which.

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
      down to 630 at that point, and 518 once the whole arm was done. `CubeReading` moved into the core with it, being three core states and no platform anything.
- [x] The identifiers move too, so a check addressing the dropdown reads the same string on either platform,
      through `AXIdentifier` on a Mac and `com.canonical.dbusmenu`'s `GetLayout` on Linux.
- [x] **The title.** `StatusItemReadout` in the core holds the first-reading latch, the title, the tick
      decision, the has-it-changed comparison and the two rules about which `debug_log` rows a change is
      worth. `redraw` turns an answer into pixels and decides nothing. **The two logging rules had no unit
      coverage at all** before this, being reachable only through a Mac-only method, so the only thing
      checking them was the scripted suite, which is set aside; they are the only way the colours are
      visible, the accessibility tree carrying none.
- [x] **The click.** `StatusItemGesture` in the core: the row every press writes, the dispatch to what each
      action ends in, and the pause that waits to see whether a press was half of a double click. What AppKit
      knows is two facts and no decisions, which side was pressed and how many clicks arrived. **The hold-back
      had no unit coverage either**, only `57-cube-pause.sh`: fifteen router tests said which action a press
      meant and none could say what happened next, that being a `DispatchWorkItem` inside a Mac-only class.
- [x] The repaint tick moved onto `Scheduler` too, so **the last hand-rolled `.common` timer in the app is
      gone** and `MenuBarController` names no `Timer` and no `RunLoop`.

**683 lines to 518**, and what is left in it is `NSStatusItem`, `NSMenu`, the attributed string and the
measuring. Four core pieces came out: `StatusItemTitle` (already there), `StatusItemMenu`, `StatusItemReadout`
and `StatusItemGesture`.

## 5. Radio

**The port.** Connect, read, write, subscribe.

`CubeRadio` already stands in the core. Behind it, `BluetoothRadio` (1,418) and `DeviceLogin` (1,482) are
2,900 lines of CoreBluetooth, and a good deal of what is in there is protocol reasoning rather than
CoreBluetooth: the command channel, the read-back matrix, the queue.

**Land `feature/commandChannel` first.** It holds candidate 1's command-channel cluster, is confirmed on
the cube, and is eight or more commits behind. Every hour it stays unmerged is an hour this section
conflicts with.

- [x] Land `feature/commandChannel`. Merged clean after thirty commits, nothing here having touched
      `DeviceLogin`. Two gates fired on it and both were right: it built a `Timer` on `RunLoop.main`, and it
      declared a `linkEnded()` nothing calls.
- [x] Take the command channel, the read-back matching and the queue into the core. `CubeCommandChannel`,
      375 lines, and 254 out of `DeviceLogin`.
- [x] Every deadline in `DeviceLogin` onto `Scheduler`: five more hand-rolled `.common` timers, which the
      clock port never reached because they sit in a platform target. That file now names no `Timer` and no
      `RunLoop` outside its default argument.
- [x] Check `CubeRadio` still says what the core needs and no more. **It does, and it is narrower than the
      arm.** Six members, all of them `DeviceReconnector`'s, and nothing in it decides anything. It is the
      reconnect loop's view of the radio rather than the radio port.

### What the arm still needs, now that both sides have been read

**The arm is not green yet and this is why.** The core reaches the radio in three different ways today: the
`CubeRadio` protocol for reconnecting, bare closures for sending (`DeviceSettingsSync` takes
`send: (Data, (Bool) -> Void) -> Void`), and not at all for the login itself. What the diagram says travels
this arm is *connect, read, write, subscribe*, and no one thing in the core says that.

**`FacetLinux` has already written the far side, and it is the shape to copy.** `BlueZRadio` is 228 lines of
power, discovery, connect, disconnect and forget; `BlueZGatt` is 122 lines of `read`, `write`,
`startNotifying`, `stopNotifying` and `nextValue`. Both are transport and neither decides anything. That is
what a radio adapter is, and it is a tenth of what `FacetMac` spends on the same job.

**The measurement that says the rest is worth doing.** `DeviceLogin` is 730 lines of code and
`BluetoothRadio` 695, and between them **74 lines mention CoreBluetooth at all**. The rest is the login
sequence, the history fetch, the factory reset, the double-tap read and the device-info gather: protocol
reasoning, all of it decided identically on both platforms and all of it currently unable to run on one.

- [x] The GATT port. `CubeGatt` is five methods, which is the whole of what the login ever did to a
      peripheral, and `CubeGattEvents` is what comes back. Addressed by UUID throughout.
      `CoreBluetoothGatt` owns the peripheral, is its delegate, keeps the UUID-to-characteristic table and
      does all the wire tracing. It decides nothing.
- [x] Move the state machine behind it. It went in one piece rather than one exchange at a time, because
      the five outbound calls were already a funnel: `DeviceLogin` is 1,303 lines in `FacetCore` now, with
      the login sequence, the history fetch, the factory reset, the double-tap read and the device-info
      gather, and no platform in any of it. Its timeout constants went with it. `CubeBytes` followed, being
      hex and ASCII and nothing to do with CoreBluetooth.
- [x] **`DeviceLogin` gets its first tests**, and they are what found the third of three bugs the move
      introduced. It never had any: it held a `CBPeripheral`, so exercising it needed a cube.
      `DeviceLoginTests` needs neither platform target and runs on both.

**The three bugs were all one bug, and the compiler was happy with every one of them.** A real adapter
answers in the canonical spelling, lowercase with the vendor's 16-bit shorthand expanded, so a comparison
against a constant as written is false: `2A29` is not `00002a29-0000-1000-8000-00805f9b34fb`. Eleven `==`
comparisons, one `switch` over the four Device Information UUIDs, and one hiding behind a local called
`awaited`. Left in, the login would have found its characteristics, presented no PIN and reported nothing.
`InMemoryGatt` answers in the spelling a real adapter answers in for exactly this reason: a double that
echoed back whatever it was handed would have agreed with the broken code.

- [ ] `BluetoothRadio` is what is left, 696 lines of code: the central manager, scanning, connecting, the
      attempt state. The core reaches it through `CubeRadio`, which is six members and only
      `DeviceReconnector`'s, so the connect half of this arm is served by a much narrower port than the
      transport half.
- [ ] Fold the send closures into the port. `CubeLock`, `DeviceSettingsSync` and `FaceColourSync` each take
      a bare `send:` closure, so the core still has three ways to reach the radio rather than one.
- [ ] **Hardware.** None of this is confirmed on a cube. It is the change on this list that most needs to
      be, and it wants one device run.

## 6. Windows and dialogs

**The port.** What to show, and which answer came back.

`SettingsWindowController` is 3,536 lines, the largest file in the app. There are 19 `NSAlert` sites, 18 of
them in that file. `CategoryRenameRules.choice(forButtonIndex:)` takes an **AppKit button index**, which is
the core reaching through the arm rather than along it.

This is last of the real work because it is the least mechanical and because items 1 to 4 all teach
something it needs.

- [x] The dialogue port. `Dialogue` is a value (heading, wording, the buttons in order, which is the way out,
      whether it is a warning); `DialoguePresenter` shows one and reports what came back. `AlertPresenter` is
      the macOS slot and `RecordingDialogues` the test one, so the seam has two adapters from day one.
- [x] `choice(forButtonIndex:)` off AppKit indices, and **deleted**: it existed in `CategoryRenameRules` and
      `CategoryCreateRules` as the same three lines of array lookup, only because an index arrived at the
      surface. The generic `ask(_:offering:)` does it once and nothing that decides sees a number.
- [x] All 19 alert sites onto the port. `SettingsWindowController` names `NSAlert` nowhere, 3,536 lines to
      3,506, and every `keyEquivalent` decision is in one file instead of four call sites that spelled it two
      different ways.
- [x] `CubeNotFoundQuestion` into the core with the rest, so `CubeNotFoundOfferTests` comes off
      `platformBoundTests` (35 files to 34) and the wording is checked on both platforms.
- [ ] Then the panes, which is its own list once the alerts are out of the way.

## 7. Storage

**Removed from the diagram on 2026-09-10, and this is the argument.**

**It is already in the core and it is not a platform capability.** All four files that touch `sqlite3_` are in
`FacetCore`: `DatabaseConnection`, `DatabaseBootstrap`, `DebugLog` and `DebugTraceFile`. The thirteen stores are
concrete types beside them with no protocol in between.

**The decisive detail is the import.** `import SQLite3` is the same line on both platforms: macOS gets the SDK
module and `Sources/SQLite3/module.modulemap` is a system-library target named after it so Linux gets one too.
Nothing in `Sources/` or `Tests/` branches on which one it got. A different import is not a different
implementation, which is the test `CLAUDE.md` sets, and it lands on shim.

**The square was the tell.** It was the only one on the figure whose slots were not platforms: SQLite, an API,
in memory for tests. Every other square reads macOS, Linux, Windows. What it was really drawing was the
intention that a remote backend would arrive as an adapter one day, and that is a deployment choice rather
than a platform one.

**The remote server turned out not to be a backend at all**, which closes the question that was in front of
this and makes removing the square right for a stronger reason than the one above. Settled by the owner on
2026-09-10: Facet always uses SQLite as its local database, and the Facet server is an *additional* thing that
can be turned on and off at will, exactly like the Google connection. Nothing replaces the database as the
source of truth.

So there is no non-SQLite adapter to write and no tension with the first design rule to resolve. `CLAUDE.md`
records the decision where the open question used to be.

**What a Facet server client will be, when it is written**, is `CalendarSync`'s shape and nothing new: a core
module holding the connection and the settings, reading them at the point of use, reaching the network through
an injected closure so it can be exercised with no account and no network, and writing anything it syncs down
into the database for the app to read back. Syncing categories down, if that is what it does, needs no rule
this codebase does not already have.

- [x] Establish whether this is an arm at all. **It is not**, on the evidence above, and the square is gone.
- [x] Settle whether a remote backend forces the database rule to relax. **The case never arises.**

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
