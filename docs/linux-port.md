# The Linux port

[← Back to README](../README.md) · [BlueZ notes →](linux-bluez-port-notes.md) · [FacetCore split →](facetcore-split.md) · [The two systems →](systems-info.md)

**The living status of running Facet on Linux.** What has been established, what is left to do, and what
is still an open question. Every claim here is either marked as measured -- with the date and the machine
-- or marked as untested. Nothing in between, because the whole value of this file is that somebody can
tell the difference without re-running the work.

**Keep it current in the same change that changes the answer.** A finding that lands without this file
moving is a finding that will be measured twice.

---

## Where it stands

| Question | Answer | When |
|---|---|---|
| Can Linux talk to the cube? | **Yes**, every stage, on real hardware | 2026-09-06 |
| Does the app's core compile on Linux? | **Yes**, 53 files, 0 errors, 0 warnings | 2026-09-06 |
| Does the logic behave? | **Yes**, 432 tests pass | 2026-09-06 |
| Can the whole test suite run? | **Under XCTest no**, `@MainActor` blocks ~60%. **Under swift-testing yes** | 2026-09-06 |
| Is there a UI? | Not started, and the toolkit is undecided | -- |
| Is there a `FacetCore` target? | **Half**: it exists, holds 86 files and compiles with 0 errors and no AppKit. `FacetApp` does not build against it yet | 2026-09-06, Mac |

**The strategy this settles: port the core, do not reimplement it.** The Swift is portable, so the
11,000 lines of decision logic and the hermetic suite come across rather than being rewritten against the
documents. That was the fork the spike existed to resolve.

## The machines it was measured on

**The Mac**, for anything below marked as measured there: macOS 26 (Darwin 25.6.0) on arm64, Xcode 26.6,
**Swift 6.3.3**. That is the answer to the toolchain question this file used to carry: the Mac is not on 6.0
and never was. `Package.swift` declares `swift-tools-version: 6.0`, which is the *language and manifest*
level the package is written to, not the compiler that builds it -- so "does the core build under 6.0"
remains genuinely unanswered, and a 6.0 toolchain would have to be installed to answer it. Nothing in the
split needed a 6.2-or-later feature.

**The Linux box**, for the rest: Linux Mint 22.3 (Ubuntu 24.04 noble base), MATE 1.26.2, kernel 7.0.0-31-generic, adapter `hci0`
(88:E9:FE:5F:1B:52). Cube `TimeFlip v2.0` at E8:DB:D8:CF:F9:0F, `DI_LABS` / `2.0` / `TFv4.1` / `FW_v3.64`.

Already present, needing no installation: BlueZ 5.72, `python3-dbus`, `python3-gi`,
`libayatana-appindicator3`, `mate-indicator-applet`. **A tray icon is native on MATE**, which is the
desktop this is being built for and is not the case everywhere -- GNOME dropped tray support and needs an
extension. A menu-bar-shaped app is a reasonable shape here.

Swift 6.2 for noble is unpacked at `~/.local/swift/swift-6.2-RELEASE-ubuntu24.04` (3.2 GB). It is not on
`PATH` by default:

```sh
export PATH="$HOME/.local/swift/swift-6.2-RELEASE-ubuntu24.04/usr/bin:$PATH"
```

---

## Found: the radio works

Full detail in [linux-bluez-port-notes.md](linux-bluez-port-notes.md); firmware behaviour in
[timeflip2-firmware-observations.md](timeflip2-firmware-observations.md) finding 12. In short: scan,
connect, resolve, log in on the vendor PIN, read every characteristic the app reads, and receive sixteen
face turns live. `scripts/linux-ble-probe.py` is the run and the reference implementation.

Two things easier than on macOS: **no pairing agent** (`Paired: 0`, `Bonded: 0` -- the PIN is the whole of
the authentication) and **no `sudo`**.

One trap that cost the first two runs: **do not filter discovery on the service UUID.** The cube
advertises none. That is finding 12, and it is why `BluetoothRadio` passes `withServices: nil`.

## Found: the core compiles

53 source files, `swift build`, **0 errors and 0 warnings**. Those 53 are the *closed set* -- the files
that reference nothing outside themselves plus Foundation -- computed rather than chosen, so the result
is not flattered by a convenient selection.

The date and timezone handling, which was the risk expected to bite hardest, produced **not one error**.
The `Locale(identifier: "en_US_POSIX")` discipline throughout the codebase is why.

### The three genuine Foundation gaps

| Gap | Where | Fix |
|---|---|---|
| `URLRequest`, `URLSession`, `URLResponse` moved to `FoundationNetworking` | `GoogleCalendarClient`, `GoogleEventClient`, `GoogleOAuthClient` | `#if canImport(FoundationNetworking)`. Mechanical; cleared 251 errors |
| `abbreviatingWithTildeInPath` does not exist in corelibs | `DebugTraceRules.swift:39` | Six lines of string handling |
| `setvbuf(stdout, ...)` | `DebugLog.swift:211` | **Unsolved.** glibc declares `stdout` as a mutable global and Swift 6 refuses every reference to it, including one captured into a `let` |

Only the third is open, and it is one line of dev-only line buffering.

### What turned out not to be a problem

- **`CoreGraphics` is one `CGFloat` typealias.** Both files that import it use nothing else.
- **`SQLite3`** needs a modulemap over the system library. The app uses 25 symbols; a hand-written header
  covered them, so the spike needed no `libsqlite3-dev`. A real port should just install it.
- Linking needs `libsqlite3.so`, and stock Mint ships only `libsqlite3.so.0`. That unversioned symlink is
  what `libsqlite3-dev` provides.

## Found: the logic behaves

**432 tests passed, 1 failed**, from 29 test files under XCTest, plus **21 of 21** in the one file
migrated to swift-testing.

The single XCTest failure is corelibs being *correct*: `applicationSupportDirectory` resolved to
`~/.local/share/Facet` and the test asserts `~/Library/Application Support/Facet`. See the XDG item below.

**Read the 432 narrowly.** Not one of them touched `TemporaryDatabase` -- every database-backed test file
is `@MainActor` and so was excluded from that run. The SQLite layer was compiled but unexercised until
`CubeLockTests` was migrated, which is the first thing to have driven a real bootstrapped database on
Linux.

## Found: `@MainActor` blocks XCTest, and swift-testing fixes it

**Under XCTest it is fatal.** Linux discovers tests through a generated `allTests` list rather than the
Objective-C reflection Apple platforms use, and it cannot cast an isolated test method:

```
Could not cast '(CubeLockTests) -> @MainActor () -> ()' to '(CubeLockTests) -> () -> ()'
```

One such class aborts the whole run with SIGABRT -- not a skip, a crash that takes every other test with
it. **60 of 100 test files** and **58 of 116 source files** carry `@MainActor`. Stripping it from the tests
does not work: they are isolated precisely because the sources they call are.

**Under swift-testing it works.** `CubeLockTests`, the file that crashed the XCTest run, was migrated and
**all 21 tests were discovered and passed**, isolation intact, against a real bootstrapped database.
That settles the strategy: the suite migrates to swift-testing rather than being rewritten or abandoned.

### What the migration actually costs

Mostly mechanical. A regex pass converted 49 of 52 assertions; the three it missed were the
message-carrying forms, `XCTAssertEqual(a, b, "why")` and `XCTAssertFalse(a, "why")`.

| XCTest | swift-testing |
|---|---|
| `final class X: XCTestCase` | `@Suite final class X` |
| `func testFoo()` | `@Test func testFoo()` |
| `XCTAssertEqual(a, b)` | `#expect(a == b)` |
| `XCTAssertTrue(a)` / `XCTAssertFalse(a)` | `#expect(a)` / `#expect(!(a))` |
| `setUpWithError()` | `init() throws` |
| `tearDown()` | `deinit` -- **and this one does not map** |

**The hazard, and it crashes rather than fails.** `tearDown` in this suite wraps its work in
`MainActor.assumeIsolated`. A `deinit` carries no actor context *even on a `@MainActor` class*, so the
assumption traps: SIGILL, no message, after every test has already reported starting. Cleanup in a
`deinit` has to be callable without isolation. Every `tearDown` in the suite needs looking at
individually for this, and it is the one part of the migration that cannot be done by pattern.

**Timing is not a concern.** The migrated file takes 23.9s for 21 tests, and `.serialized` and
`--no-parallel` make no difference, because it is not contention: applying the DDL costs ~1.15s, measured
independently in plain Python and sqlite3, and each test bootstraps its own database. That is the test
design, not a Linux regression.

## Found: a symlinked directory reads as empty, and the bootstrap calls that success

**Two faults that compound, and the repository is already arranged to trigger them.**

`FileManager.contentsOfDirectory(at:)` returns an **empty array** for a symlinked directory on Linux.
Darwin follows the link. Measured 2026-09-06, same directory, same process:

| | `contentsOfDirectory(at: URL)` | `contentsOfDirectory(atPath:)` | `at:` after `resolvingSymlinksInPath()` |
|---|---|---|---|
| **through a symlink** | **0** | 15 | 15 |
| the real path | 15 | 15 | 15 |

`database/` at the root of this repository **used to be** the symlink, pointing into
`Sources/FacetApp/Resources/Database`. **Fixed 2026-09-06 by flipping it**: `database/` is now the real
directory and the path under `Sources/` is the symlink, because the schema is shared and neither platform
owns it -- the only reason it ever lived inside the macOS target is that SwiftPM requires a target's
resources to sit inside the target, and SwiftPM does follow the link when bundling (verified on Linux;
the macOS build is what the next scripted run confirms).

`TemporaryDatabase.ddlDirectory` moved to `database/` in the same change, so **no runtime code path
traverses a symlink at all** now. Only SwiftPM's resource bundling does, at build time.

And the second fault is what turns a wrong answer into a silent one. `DatabaseBootstrap.ensureDatabase`
filters the listing and applies what survives; **an empty listing applies nothing and returns
successfully** -- `createdDatabase: true`, `filesApplied: []`, no error thrown. The result is a database
with no tables, reported as a database that was created. That is how this was found: every setting read
came back `nil` and nothing anywhere said why.

**Both halves are fixed** (2026-09-06). `DatabaseBootstrap.ensureDatabase` resolves symlinks before it
enumerates, and throws a new `Failure.ddlDirectoryEmpty` rather than returning success on an empty
listing. The second is a fix on macOS as much as Linux: a DDL directory yielding no files is never a
correct outcome, and `CLAUDE.md` already carries the rule it broke -- nothing fails silently. The Linux
symlink behaviour exposed it rather than causing it.

Verified against the exact failure case: with the DDL reachable only through a symlink, the 21 migrated
`CubeLockTests` pass, where before the same arrangement produced a database with no tables and reported
it as created.

### And SwiftPM does follow the symlink on macOS, which was the open risk in `7ade2c7`

**Measured on the Mac, 2026-09-06, and again after the split moved the link.** `swift build`, then look
in the built bundle: all **13** `.sql` files are there. Flipping `database/` to be the real directory did
not cost the macOS app its schema, so the commit that did it is safe on both platforms.

One detail worth having written down, because it looks like a fault and is not: **`.process` flattens,
so the files land at the root of the bundle and there is no `Database/` directory in it.** That is why
`DatabaseBootstrap.bundledDDLDirectory` asks for `001_event_type.sql` by name and strips the filename
rather than asking for a directory -- the code already expects this, and its comment says so.

After the split the link lives at `Sources/FacetCore/Resources/Database` and its text is unchanged,
`../../../database` reaching the repository root from the new depth exactly as it did from the old.
The bundle is `FacetApp_FacetCore.bundle` and holds the same 13 files.

## Found: a real module split needs 94 types widened, not 103

**Measured on the Mac, 2026-09-06**, by making the split rather than by counting declarations. This
section replaces an estimate taken from a script on the Linux side; the estimate is left in the table
below so the two can be compared.

`Sources/FacetCore` now exists and holds **86 files**. It compiles as its own module with **0 errors**,
and **nothing in it imports AppKit**. `Sources/FacetApp` holds the other **35**.

| | Estimated, from Linux | Measured, on the Mac |
|---|---|---|
| Types the AppKit half names from the portable half | 103 | **94** |
| Member declarations, an upper bound on the widening | ~511 | **not yet known** |
| `public`/`package` keywords in `Sources/` | 0 | 0, still |

**The member number is not measurable from one build and that is the finding, not an omission.** The
first build of `FacetApp` against `FacetCore` reports **4,801 error lines**, and the 94 types are all
that can be read off them: until a type is visible, the compiler cannot say which of its members are
wanted, so member errors appear only as each type is widened. 2,120 of those lines are already
`cannot infer contextual base in reference to member`, which is the member work starting to surface
underneath the type work. The real member count comes out of running the loop, and only then.

**The stage 3 recipe in [facetcore-split.md](facetcore-split.md) greps for the wrong string.** It looks for

```
is internal and cannot be referenced|initializer is inaccessible
```

and neither appears. An `internal` declaration in another module is not visible at all rather than
visible-and-refused, so what the compiler actually says is:

```
error: cannot find 'CategoryStore' in scope
error: cannot find type 'CategoryRecord' in scope
```

The grep to drive the loop with is `cannot find (type )?'X' in scope`, and the useful form is the
distinct sorted list of names inside the quotes.

## Found: the layer boundaries are better than the file count suggests, with two corrections

The three structural facts below were established from Linux. **Two of them were right and one was
incomplete**, which the compiler settled on the Mac on 2026-09-06:

- **`BluetoothRadio` is named 21 times across 13 core files, and referenced in code twice.** Confirmed.
  Both references were in `DeviceReconnector`, and they now go through a five-member `CubeRadio`
  protocol that `BluetoothRadio` conforms to. Nothing else in the core names the radio in code.
- **Six files import AppKit for `NSColor` and nothing else.** **Five of them do.** The sixth,
  `StatusItemTitle`, is not a data file and cannot be made one -- see below.
- **The one genuine leak is `AppSettingsRules` reaching into `AppSettingsPane.Change`.** **There were
  two.** The second is `GoogleCalendarClient`, in the core, calling `GoogleCredentials.resolve()`,
  where `GoogleCredentials` was declared inside `GoogleOAuthClient.swift` alongside the `NWListener`
  that keeps that file on the platform side. It is pure Foundation and moved out to its own file in
  the core, exactly as `AppSettingsPane.Change` did. The DDL is not the only resource that had to
  follow its reader: `google-client.json` moved to `Sources/FacetCore/Resources/` with it, because
  `GoogleCredentials.builtIn` reads it through `Bundle.module` and that accessor is per-target.
  `.gitignore` and `scripts/generate-credentials.sh` name the new path.

### `StatusItemTitle` stays on the platform side, and it is not a file-count problem

**It is the one file on the 83-file move list that the split had to refuse.** Its colours are
deliberately *semantic* AppKit ones -- `.labelColor`, `.systemCyan`, `.systemRed`, `.systemGreen`,
`.systemYellow` -- and the file already carries the reason above the property: the menu bar tints from
the wallpaper rather than from the appearance setting, so a colour resolved before the draw is a frozen
answer. Four fixed components cannot express that. `colourDescription` also switches on those constants
to put the drawn line into words, which is what the scripted checks read, the accessibility tree
carrying no colour at all.

So the portable colour type is **`Colour`**, four sRGB `Double`s, and it covers the other five:
`CategoryStore`, `TimeEntryStore`, `ColourStore`, `FaceColourRules` and `DeviceFaceRules`. The UI
converts at the point it draws, through `Colour.nsColor`. A Linux UI needs its own equivalent of
`StatusItemTitle` regardless, tray text being a toolkit question rather than a shared one.

Two consequences worth knowing before the same conversion is done anywhere else:

- **`FaceColourRules` no longer converts to sRGB before reading channels**, `Colour` holding no other
  space. The branch that treated an unconvertible colour as off went with the failure it handled.
- **`NSColor.black` and `.white` are Generic Gray, and `Colour.black.nsColor` is sRGB.** The same
  pixel, but `NSColor` equality compares the space, so a test asserting a drawn colour against the
  AppKit constant fails after the conversion. `TimingViewTests` asserts against the ink itself now.

### Two files were carrying an `import AppKit` they had stopped needing

`CollapsibleSection` (a protocol with no `NS` type in it at all) and `FaceColourSync` (whose need went
away the moment `FaceColour.colour` stopped being an `NSColor`). Both are Foundation-only now. Neither
was visible from the Linux side, which computed the move list from the import lines themselves -- so
**an import line is evidence of what a file needed once**, and the compiler is the only authority on
what it needs now.

### What the core still imports besides Foundation

All four are already to-do items below, and none is new:

| Import | Files | Item |
|---|---|---|
| `SQLite3` | 4 | Needs a modulemap or `libsqlite3-dev` |
| `Security` | 2 (`DevicePINStore`, `GoogleTokenStore`) | 7, libsecret |
| `CoreGraphics` | 2 (`SettingsMetrics`, `ReportCalendarMetrics`) | One `CGFloat` typealias |
| `CryptoKit` | 1 (`GoogleOAuthRules`) | 8, swift-crypto |

---

## To do

Roughly in dependency order. Nothing here is started.

1. ~~**Settle the `@MainActor` question.**~~ Done. It came first because it decides how the
   test target is structured, and doing the extraction first would mean restructuring it twice.
   **Answered 2026-09-06: swift-testing.** What is left is doing it to the other 59 files.
2. **Separate the platform half from the portable half.** **Under way on the Mac since 2026-09-06, and
   the `FacetCore` route was the one taken.** Stages 1 and 2 of
   [facetcore-split.md](facetcore-split.md) are done and committed:
   - ~~The three decouplings.~~ Done. `AppSettingsPane.Change` is now the top-level `AppSettingsChange`;
     five of the six `NSColor` files carry `Colour`; `DeviceReconnector` depends on a `CubeRadio`
     protocol. A fourth was needed and is done with them: `GoogleCredentials` out of
     `GoogleOAuthClient.swift`.
   - ~~The target, and the files into it.~~ Done. 86 files in `FacetCore`, 35 in `FacetApp`,
     `FacetCore` compiling with 0 errors and no AppKit, the DDL and `google-client.json` moved to its
     resources.
   - **Stage 3, the access-level loop, has not been started**, and it is the decision this is stopped
     at. 94 types, an unknown number of members, and `FacetApp` does not build until it is finished.
     **The `#if canImport(AppKit)` fallback is still available and costs no access changes at all** --
     what is needed downstream is that the portable half compiles without AppKit, which two targets
     are one way of getting and not the only one.
3. **Platform-aware data directory.** `~/Library/Application Support/Facet` is a literal in four source
   files -- `DebugTraceRules.swift:24`, `DatabaseBootstrap`, `InstanceLock`, `DeveloperConfigFile` -- in
   10 test files, and, awkwardly, **in the seeded `debug` row of `database/011_setting.sql`**. The DDL one
   is the difficult case: it is a database value rather than code, and the database is the source of truth.
4. **The three Foundation gaps** above.
5. ~~**Make `DatabaseBootstrap` refuse an empty DDL listing**, and resolve symlinks before
   enumerating.~~ Done 2026-09-06, along with flipping `database/` to be the real directory.
6. **Migrate the test suite to swift-testing**, checking every `tearDown` by hand for the `deinit`
   isolation trap. Mechanical for the assertions, not for the lifecycle.
7. **`Security` to libsecret.** Two files, `DevicePINStore` and `GoogleTokenStore`, both already behind a
   store interface, both excluded from the spike as a known answer.
8. **`CryptoKit` to swift-crypto.** One file, `GoogleOAuthRules`, one `SHA256.hash` call for PKCE.
9. **`Network` to a plain socket listener.** One file, `GoogleOAuthClient`, an `NWListener` for the OAuth
   loopback redirect.
10. **The BlueZ backend in Swift.** Roughly 600-1000 lines behind the interface `BluetoothRadio` already
   presents. `scripts/linux-ble-probe.py` is the working reference for every D-Bus call it needs.
11. **The UI**, once the toolkit is decided.
12. **The scripted suite on AT-SPI.** The largest single piece, and the only thing that can say the app
    works. `Tests/Methods.md` techniques survive; the locator layer is new.
13. **Repo restructure and the `CLAUDE.md` split.** Agreed: one repo, shared core. About a third of the
    root `CLAUDE.md` is AppKit-specific and would be worse than noise in a GTK session. Also resolves the
    `database/` symlink, which currently points into the macOS bundle resources -- and which the
   symlink finding above makes more than a tidiness question.
14. **README.** Links this file from its docs list, and otherwise still describes a macOS-only project.
    Rewriting it to describe two platforms waits for item 13, rather than being half-applied now.

## To check

Open questions, with what would answer each.

| Question | How to answer it |
|---|---|
| **Does the core build on Swift 6.0?** Still open, and the premise was wrong: **the Mac builds with 6.3.3**, not 6.0. The tools-version line is the manifest level, not the compiler. Linux used 6.2 | Install a 6.0 toolchain on either box and repeat. Nothing in the split needed a post-6.0 feature, so this is a check rather than an expectation |
| **Do the other 61 test files pass?** They were excluded for referencing types outside the closed set, not for failing | Widen the closed set as `FacetCore` takes shape |
| **How many `tearDown` methods hit the `deinit` isolation trap?** One per file at worst, and it crashes rather than fails | Grep for `MainActor.assumeIsolated` in tearDown across the 60 blocked files |
| **Is `contentsOfDirectory(at:)` on a symlink a known corelibs bug or intended?** Worth reporting upstream if the former | Check the swift-corelibs-foundation tracker |
| ~~**Does SwiftPM follow the symlinked resources directory on macOS?**~~ **Yes**, before and after the split: 13 `.sql` files in the built bundle, flattened to its root | Answered 2026-09-06, Mac |
| ~~Does `Thread.isMainThread` matter?~~ **No.** It reads `false` inside a `@MainActor` test on Linux -- isolation holds, the OS thread simply is not thread 1 -- and nothing in `Sources/` calls it | Answered 2026-09-06 |
| ~~**What do the 41 platform files actually need?**~~ **35 of them, and now assessed by the compiler.** `FacetApp` is what did not move: the panes and views, `BluetoothRadio`, `DeviceLogin`, `BLETrace`, `TimeFlipUUIDs`, `MenuBarController`, `MainMenu`, `ActivityIcon`, `GoogleOAuthClient`, `QuitSequence`, `StatusItemTitle`, `ColourDrawing` and `main.swift` | Answered 2026-09-06, Mac |
| **How many members does stage 3 actually have to widen?** The type count is 94, measured; the member count cannot be read off one build because the errors cascade | Run the loop. It is the number that is still an estimate |
| **Does the scripted suite still pass after the split?** `Sources/` moved wholesale and `Tests/Scripted/last-run.md` is stale from `7ade2c7` regardless | One run with a cube, covering both |
| **Does the rename apply immediately or is it deferred?** Open since August; finding 1 wants a second BLE central with no cached record, and this box is one | Rename from the Mac, read the GAP name from Linux |
| **Does the `T.Flip` manufacturer data survive a rename?** If it does, a renamed cube has two stable markers | Rename, then re-read `ManufacturerData` |
| **Is the static random address stable across a power cycle or factory reset?** The BLE spec permits it to change | Pull the batteries, re-scan, compare |
| **Does the Google OAuth loopback flow work on Linux?** The listener is replaceable, but the flow is untested end to end | After item 7, with a real Google account |
| **What is the state of Swift GTK3 bindings?** MATE 1.26 is GTK3, and the binding work known to exist targets GTK4 | Survey before committing to a single-process design |
| **Does `swift build` work with real `libsqlite3-dev`?** The spike used a hand-written 25-symbol header | Install the package and drop the shim |

## Decisions outstanding

**The UI architecture, which is the owner's call.** Two candidates:

- **One process, Swift + GTK3.** Keeps everything in one language. Risk: the binding maturity question above.
- **Two processes, Swift core plus a Python/GTK3 tray and settings UI, with SQLite as the IPC.** No
  protocol to invent, and it fits the app's own architecture -- nothing holds state, everything reads the
  database at the point of use, so a second reader is free. PyGObject and the appindicator bindings are
  already installed on this machine. Needs care over WAL mode with a busy timeout, and `InstanceLock`
  becomes per-process rather than per-app.

The second is the lower-risk recommendation, and it is not yet decided.

---

## Reproducing the spike

Nothing below is committed; it all ran in a scratch directory.

```sh
export PATH="$HOME/.local/swift/swift-6.2-RELEASE-ubuntu24.04/usr/bin:$PATH"

# The radio, against a real cube. Quit Facet on the Mac first -- one connection at a time.
python3 scripts/linux-ble-probe.py
```

The compile and test spike was assembled by computing the closed set of source files, copying them to a
scratch package with a `CSQLite` system-library target, applying the three Foundation fixes, and adding
the test files that reference only closed-set types. It is not checked in, being a measurement rather
than an artefact. The findings above are what it produced.
