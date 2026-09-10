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

| # | Arm | Why here |
|---|-----|----------|
| 0 | Housekeeping | Three corrections that cost nothing and are noise in every scan until they go. |
| 1 | The clock | Six core modules on `RunLoop.main`, which `FacetLinux` never runs. A live latent fault, and half the seam already exists. |
| 2 | Files and folders | Nothing on Linux can start up correctly until this moves. Small, concrete, four files each way. |
| 3 | Starting and stopping | Most of it landed with `QuitSequence` on 2026-09-10. Finishing it while it is fresh is the cheapest arm left. |
| 4 | Menu bar | The **second adapter already exists** and is the right shape. A real seam with one outlier, not a hypothetical one. |
| 5 | Radio | The biggest port with a protocol already standing. Wants `feature/commandChannel` landed first. |
| 6 | Windows and dialogs | 3,536 lines and the least mechanical work in the app. Everything above teaches something it needs. |
| 7 | Storage | Deferred on purpose. See its section: it is one adapter, and the decision behind it is unsettled. |

Reorder this table as the work teaches something. An item that turns out to block another moves above it,
and the move gets a line saying what was discovered.

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

**The port.** Something in the core that says *wake me in N seconds*, and one that says *what time is it*.
Nothing more: the diagram's arm is two sentences wide on purpose.

**Why first.** Six core modules build a `Timer` and add it to `RunLoop.main`: `DailyLimitWatch`,
`DeviceReconnector`, `LowBatteryWatch`, `HistoryTimer`, `QuitSequence`, `WriteDebounce`. `FacetLinux` never
runs `RunLoop.main`, so on Linux **not one of those timers will ever fire**. That is a production fault
sitting in the core today, and it is the clearest case in the codebase of the core caring what platform it
is on while insisting it does not.

**Half the seam exists already.** `HistoryTimer.fire()`, `LowBatteryWatch.fire()` and `WriteDebounce.fire()`
are internal so a test can take the place of the run loop. That is the port in embryo: the decision is
already separated from the thing that schedules it. Three modules do not have it.

- [ ] Name the port and put it in the core, with the hand-driven adapter the tests already want.
- [ ] `WriteDebounce` first: smallest, one timer, `fire()` already there.
- [ ] `HistoryTimer` and `LowBatteryWatch`: same shape, `fire()` already there.
- [ ] `DailyLimitWatch`: needs a `fire()` before it can move.
- [ ] `DeviceReconnector`: three timer sites, the most tangled.
- [ ] `QuitSequence`: the five second deadline, moved on 2026-09-10 and still on `RunLoop.main`.
- [ ] The macOS adapter in `FacetMac`, injected from `main.swift`.
- [ ] Widen `PlatformBlindCoreTests` to fail on `RunLoop.main` in the core, now that nothing needs it.

## 2. Files and folders

**The port.** Where my data lives, and the lock that says only one of me is running.

**Why second.** `FileManager.default.urls(for: .applicationSupportDirectory, ...)` is in
`DatabaseBootstrap`, `DeveloperConfigFile`, `DebugTraceRules` and `InstanceLock`. On Linux the answer is
XDG, and it is a different answer rather than a different spelling, so every one of those is a port by the
test above. None of them carries a `#if`, so the platform-blindness check has never seen any of it.

`InstanceLock` is the sharpest example in the whole codebase: `flock`, `errno` and `strerror` with **zero**
platform conditionals in the file.

`Bundle.main` is the same question wearing a different hat, in `DatabaseBootstrap`, `DevicePINStore`,
`GoogleCredentials` and `GoogleTokenStore`.

- [ ] The port: the directories the app uses, asked for by role rather than by path.
- [ ] Move the four `applicationSupportDirectory` readers onto it.
- [ ] Move the four `Bundle.main` readers onto it.
- [ ] `InstanceLock`: the decision stays in the core, the `flock` goes to `FacetMac`.
- [ ] Widen the check to fail on `applicationSupportDirectory` and `Bundle.main` in the core.

## 3. Starting and stopping

**The port.** May I stop yet, and now you may.

Mostly done. `QuitSequence` moved into the core on 2026-09-10 and `QuitDelegate` is the macOS adapter,
holding the protocol conformance and nothing else. What is left is the other end: `app.run()`, and the
launch sequence in `main.swift` that is still written as an AppKit program rather than as a composition
root that happens to be on a Mac.

- [ ] Name the port for the half that is not the quit.
- [ ] Read `main.swift` against it and move what is core out of the launch sequence.
- [ ] Confirm `QuitSequence`'s deadline moves with item 1 rather than being left behind.

## 4. Menu bar

**The port.** A title, a menu, a click and which side it was.

**Why here, and why it is the most instructive one.** `Sources/FacetLinux/MenuBar.swift` is 191 lines of
GTK that decides nothing: it takes closures and reads them, and knows nothing about a category.
`MenuBarController` is 683 lines and is not that shape. So this is a **real seam with two adapters**
already, where one of them is right, which makes it the only port on this list with a worked example
sitting in the repo.

`CLAUDE.md` already says to point at the Linux one when in doubt.

- [ ] Read `MenuBarController` against `FacetLinux/MenuBar.swift` and mark every line that decides something.
- [ ] Move the decisions into the core, leaving `NSStatusItem` and the drawing.
- [ ] The port is whatever the Linux one already takes, which is the point.

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
