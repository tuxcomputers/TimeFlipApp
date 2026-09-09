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
| Does the app's core compile on Linux? | **Yes -- `FacetCore` entire**, 89 files, 0 errors, 0 warnings, from a deleted `.build` in 13s | 2026-09-07, Linux |
| Does the logic behave? | **Yes**, 432 tests pass | 2026-09-06 |
| Can the whole test suite run? | **Under XCTest no**, `@MainActor` blocks ~60%. **Under swift-testing yes** | 2026-09-06 |
| Does any of the suite run on Linux? | **Yes. `swift test` passes 1,049 of 1,751 tests** across 65 suites -- 590 under XCTest in 2.8s, 459 under swift-testing in 55s. Of the 40 files still excluded, 38 need AppKit, CoreBluetooth or a `FacetMac` type and come back with items 10 and 11; the other 2 need the main thread's run loop, which is a different problem and has its own section below | 2026-09-09, Linux |
| Can Swift talk to BlueZ? | **Yes, in process, over libdbus.** `SystemBus` calls methods, marshals arguments both ways and receives signals with typed values; seven tests drive it against the real system bus | 2026-09-07, Linux |
| Can it discover? | **Yes**, and the cube is found by `DeviceScanRules` -- the app's own rule, unchanged | 2026-09-07, Linux |
| Can it drive the cube from Swift? | **Yes, every stage the app needs.** Connect, resolve, 16 characteristics by UUID, log in on the vendor PIN, read, the `0x10` status read-back parsed by the app's own rules, and **face turns arriving as notifications -- ten pushes over seven distinct faces**. Nothing but the PIN and `0x10` has been written | 2026-09-07, Linux |
| Is there a UI? | **A menu bar item, and that settles the toolkit.** Swift calling GTK3 and `AyatanaAppIndicator3` through a modulemap, one process, one language. No Settings window yet | 2026-09-09, Linux |
| Does the app run on Linux? | **Yes.** It boots, takes the instance lock, applies the DDL, puts an icon in the bar and quits from its own menu | 2026-09-09, Linux |
| Can a GTK3 app be driven by a test harness? | **Yes, and the tray over D-Bus rather than AT-SPI.** Press, type, toggle and read back, all without a mouse and while the window is covered. Measured against a stand-in, not against Facet | 2026-09-08, Linux |
| Is there a `FacetCore` target? | **Yes.** 86 files, no AppKit, and `FacetMac` builds on it. 589 access-level edits | 2026-09-07, Mac |
| ~~What is left before Linux can try the core?~~ | **Nothing. All four are done**: `SQLite3` has a modulemap target, `CoreGraphics` a `package typealias`, `Security` the login keyring through `secret-tool`, `CryptoKit` a written SHA-256 | 2026-09-07, Linux |
| What is left before Linux can **run** anything? | The suite (item 6, swift-testing) to know it behaves; then item 9 for sign-in and item 10 for the radio. Both of those are in `FacetMac`, not the core | 2026-09-07, Linux |
| Does CI check any of this? | **Yes, since today, and it did not before.** A `test-linux` job runs `swift build`, starts a private `dbus-daemon`, then `swift test` on `ubuntu-latest` in a `swift:6.2-noble` container -- **1,047 tests**, being the 1,042 the Mac also runs plus 5 of the 7 D-Bus ones. `all-tests-pass` requires it. Only 2 are skipped, both needing a real BlueZ adapter | 2026-09-09, Linux |
| Does the core actually run outside `swift test`? | **Yes.** A real binary linked against it resolves the XDG data directory, applies the DDL through the bundle, takes the instance lock against a second process and reaches the keyring. One fault found: the resource bundle (below) | 2026-09-08, Linux |

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

**The Linux box**, for the rest: Linux Mint 22.3 (Ubuntu 24.04 noble base), MATE 1.26.1, kernel 7.0.0-31-generic, adapter `hci0`
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

## Found: the core compiles -- and now the whole of it does

**`swift build --target FacetCore` completes on Linux: 89 files, 0 errors, 0 warnings, from a deleted
`.build` in 13 seconds** (2026-09-07). No `-Xcc`, no scratch package, no selected subset: the target as
it stands in the tree, with its resource bundle carrying all 17 `.sql` files.

The spike's number was **53 files** -- the *closed set*, being those referencing nothing outside
themselves plus Foundation, computed rather than chosen so the result was not flattered by a convenient
selection. What stood between that and the whole target was four modules, and all four are now closed:
`SQLite3` (a `systemLibrary` target), `CoreGraphics` (one `package typealias`), `Security` (the login
keyring, item 7) and `CryptoKit` (a written SHA-256, item 8).

The date and timezone handling, which was the risk expected to bite hardest, produced **not one error**.
The `Locale(identifier: "en_US_POSIX")` discipline throughout the codebase is why.

**What this does and does not mean.** The portable half compiles and links its own module; nothing here
says it *behaves*, because `swift test` still cannot run on Linux -- that is item 6, and it is now the
single thing standing between a compiling core and a verified one. Nor is there anything to run: the
executable is `FacetMac`, which is AppKit, so a Linux binary waits on items 9, 10 and 11.

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
  **And it still needs the modulemap after installing it** -- measured 2026-09-07 on Linux, with
  `libsqlite3-dev` present and `import SQLite3` failing exactly as before, because the Swift toolchain
  ships no `SQLite3` module for this platform. The package is what lets the modulemap name the real
  `/usr/include/sqlite3.h` and lets a link find `libsqlite3.so`; it is not a substitute for it.
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

**The 2026-09-09 pass converted 264 of 264**, across the last four files, with a string- and comment-aware
converter rather than a plain regex -- which is what the message-carrying forms need, along with two traps a
regex walks into. An operand whose top level holds an operator binding looser than `==` has to be
parenthesised, or `XCTAssertEqual(a ?? b, c)` becomes `#expect(a ?? b == c)`, which compiles and asks
`a ?? (b == c)`; and a `String` variable passed as a message is not a `Comment`, where a string literal
becomes one on its own. Neither of those fails loudly, which is why the count was checked per file against
the original rather than trusted.

| XCTest | swift-testing |
|---|---|
| `final class X: XCTestCase` | `@Suite final class X` |
| `func testFoo()` | `@Test func testFoo()` |
| `XCTAssertEqual(a, b)` | `#expect(a == b)` |
| `XCTAssertTrue(a)` / `XCTAssertFalse(a)` | `#expect(a)` / `#expect(!(a))` |
| `try XCTUnwrap(a)` | `try #require(a)` |
| `setUpWithError()` | `init() throws` |
| `tearDown()` | `deinit` -- **and this one does not map** |

**The hazard, and it crashes rather than fails.** `tearDown` in this suite wraps its work in
`MainActor.assumeIsolated`. A `deinit` carries no actor context *even on a `@MainActor` class*, so the
assumption traps: SIGILL, no message, after every test has already reported starting. Cleanup in a
`deinit` has to be callable without isolation. Every `tearDown` in the suite needs looking at
individually for this, and it is the one part of the migration that cannot be done by pattern.

**Timing was not a concern, then briefly was, and is not again.** The spike measured 23.9s for 21 tests
with `.serialized` and `--no-parallel` making no difference, because the cost was the DDL apply that
every test pays in its own bootstrap -- the test design rather than a Linux regression.

**Then the seeded `timezone` table turned that cost into a wall** (2026-09-07). 448 zones plus 151
aliases is 599 more statements per bootstrap, and sqlite gives every statement outside a transaction one
of its own with an fsync attached: 6.2s per test, at which point 292 tests in parallel never finished a
single one in ten minutes. Not contention -- each test simply held a database open for six seconds while
the next began.

**Fixed by applying each DDL file in one transaction**, which is a 64-fold difference on the seed file
alone (3.87s to 0.06s) and takes a bootstrap from 6.2s to 0.9s. The 540 XCTest tests went from 38.1s to
**2.0s** with it, and the 292 migrated ones run in **42s in parallel**. So the answer stands where the
spike left it -- parallelism is fine and `.serialized` is not needed -- but for a different reason than
it gave, and the number that matters is the per-statement fsync rather than the DDL's size.

### And it does not fix everything: on Linux, `@MainActor` is not the main thread

**Measured 2026-09-09**, migrating the last six files off the exclusion list. Inside a `@Suite @MainActor`
swift-testing suite on this platform:

| Probe | Answer |
|---|---|
| `Thread.isMainThread` | **false** |
| `RunLoop.current === RunLoop.main` | **false** |
| a `Timer` on `RunLoop.main` in `.common`, spinning `.default` | **never fires** |
| the same on `RunLoop.main` in `.default`, spinning `.default` | **never fires** |
| the same on `RunLoop.current` in `.common`, spinning `RunLoop.current` | **fires at once** |

The isolation is honoured -- the body really is serialised on the main actor -- but the actor is not the
thread whose run loop `RunLoop.main` hands back. Under XCTest the two coincided. No migrated suite had
noticed because all 22 of them are synchronous and none of them touches a run loop.

**It cost the last two files of the migration.** `WriteDebounce.schedule` and `LowBatteryWatch`'s blink
timer both do `RunLoop.main.add(timer, forMode: .common)`, so under swift-testing here the timer lands on a
run loop the test cannot drive and nobody else is running. `WriteDebounceTests` (7 tests) and
`LowBatteryWatchTests` (10) would trade one load-time abort for seventeen silent failures, so they stay
excluded, and `Package.swift` now names this as the reason rather than the framework. It was confirmed the
expensive way: the migrated `WriteDebounceTests` reported `writes -> 0` and `written -> []` on four tests
before the probe explained why.

**Two ways out, and neither is free.** swift-testing could run `@MainActor` on the main thread on Linux,
which is not in this repository's gift. Or the `RunLoop` becomes a parameter of the two subjects, defaulting
to `.main` -- a production change made for a test's benefit, and worth agreeing before doing rather than
after. `RunLoop.main` states what the app actually wants; switching those call sites to `RunLoop.current`
would pass the tests by coincidence and leave the app correct only for as long as the main actor happens to
be the main thread, which is precisely the assumption this section just measured as false.

**A smaller Linux-only difference found beside it.** swift-corelibs-foundation does not mark
`RunLoop.run(mode:before:)` `@discardableResult`, so the bare call warns here where it does not on Darwin.
The repository's four other call sites are all in macOS-only test files, which is why it had never come up.

## Found: a symlinked directory reads as empty, and the bootstrap calls that success

**Two faults that compound, and the repository is already arranged to trigger them.**

`FileManager.contentsOfDirectory(at:)` returns an **empty array** for a symlinked directory on Linux.
Darwin follows the link. Measured 2026-09-06, same directory, same process:

| | `contentsOfDirectory(at: URL)` | `contentsOfDirectory(atPath:)` | `at:` after `resolvingSymlinksInPath()` |
|---|---|---|---|
| **through a symlink** | **0** | 15 | 15 |
| the real path | 15 | 15 | 15 |

`database/` at the root of this repository **used to be** the symlink, pointing into what was then
`Sources/FacetApp/Resources/Database` (that target is called `FacetMac` now, and the link has since moved
to `FacetCore` anyway). **Fixed 2026-09-06 by flipping it**: `database/` is now the real
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
The bundle is `Facet_FacetCore.bundle` and holds the same 13 files.

## Found: a real module split needs 589 access-level edits, and it is done

**Measured on the Mac, 2026-09-07**, by making the split rather than by counting declarations. This
section replaces an estimate taken from a script on the Linux side; the estimate is left in the table
below so the two can be compared.

**`FacetCore` is real and the whole package builds on it.** 86 files in the core, 35 in `FacetMac`,
**nothing in the core importing AppKit**, `swift build` clean with no warnings, and **1718 tests passing
with none skipped**.

| | Estimated, from Linux | Measured, on the Mac |
|---|---|---|
| Types that had to be widened | 103 | **152** |
| Members that had to be widened | ~511 (upper bound) | **437** |
| **Total `package` declarations** | ~614 | **589** |
| `public` keywords anywhere | 0 | **0**, still |
| `package` keywords in `FacetMac` | -- | **0** |

**The type count was low by half, and the reason is worth knowing before estimating this kind of change
again.** The script counted the types `FacetMac` names directly. What the compiler asks for is those
plus everything that comes with them: a type used in a `package` signature, a nested type behind a
`package` enum case, and a parent that has to widen so its own nested type is reachable at all. The
member count came in **under** its upper bound, which is what an upper bound is for.

**It cannot be read off one build.** The first build of `FacetMac` against `FacetCore` reported 4,801
error lines naming 94 types; widening those exposed the next layer, and so on for a dozen rounds. Until
a type is visible the compiler cannot say which of its members are wanted.

**What made the loop tractable: Swift emits `note: 'x' declared here` beside each access error, carrying
the declaration's own file and line.** That is the whole input a widening pass needs -- no name matching,
no inferring a receiver's type, nothing widened that the build did not point at. The first attempt
matched on member names instead and was ambiguous for 15 of 70; the note-driven pass had no ambiguity at
all.

**Two guesses did creep in, and the compiler caught both**, which is the argument for the discipline
rather than against it: `package` on three local `let`s inside function bodies, where it is a compile
error rather than merely wrong, and a generated memberwise initialiser that had swept up locals from the
function bodies of the struct it belonged to.

**Seven memberwise initialisers had to be written by hand**, Swift not widening a synthesised one with
its type. That is the only part of the stage that is not mechanical. Two needed care beyond copying the
stored properties: `DevicePINSource` stores two closures and so needs `@escaping`, and `DeviceInfo`
needed its four optionals to keep the `nil` defaults the synthesised initialiser had given them, which
is what `DeviceLogin` relies on when it writes `DeviceInfo()`.

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

### What the core imported besides Foundation, and what each became

**All four are closed as of 2026-09-07**, in the order the compiler hit them -- each import being
unguarded, each was a hard stop hiding the next:

| Import | Files | What it is now |
|---|---|---|
| `SQLite3` | 4 | A `systemLibrary` target named `SQLite3`, depended on `.when(platforms: [.linux])` so Darwin keeps its SDK module. Needs a modulemap **and** `libsqlite3-dev`, not either/or -- see below. No source file changed |
| `Security` | 2 (`DevicePINStore`, `GoogleTokenStore`) | The login keyring through `secret-tool` (`SecretToolStore`), branched at compile time inside both stores. Item 7 |
| `CoreGraphics` | 2 (`SettingsMetrics`, `ReportCalendarMetrics`) | One `package typealias CGFloat = Double` in `CoreGraphicsShim`. It has to be `package` -- a plain one trades four missing-module errors for 22 access errors |
| `CryptoKit` | 1 (`GoogleOAuthRules`) | `PortableSHA256`, 60 lines, compiled everywhere and called only on Linux. Item 8 |

**All four confirmed from Linux 2026-09-07, in that order, and there is no fifth.** The compiler hits
them one at a time -- each import is unguarded, so each is a hard stop that hides the next -- so they
were peeled with a modulemap over the real `sqlite3.h` and a detached worktree, to see the whole list
rather than the first of it. What is behind all four is **76 errors in three files and nothing in the
other 83**: 75 diagnostics over 19 distinct `Security` symbols in the two Keychain stores, and one
`SHA256` call in `GoogleOAuthRules`. Both `CoreGraphics` files compile clean once the typealias is
right, and **`package typealias CGFloat = Double` is what right means** -- a plain one is `internal`,
which a `package` member may not use, so the naive fix trades four missing-module errors for 22 access
errors. Full working in the *What `FacetCore` does on this box* section of
[systems-info.md](systems-info.md).

---

## Found: a GTK3 app is drivable, and the tray is easier than it is on the Mac

**Measured on the Linux box, 2026-09-08, against a stand-in rather than against Facet** -- there is no
Linux app yet, so this was a 90-line Python/GTK3 process shaped like the parts a scripted check has to
reach: a window with named controls, an `AyatanaAppIndicator3` tray item with a menu, and an append-only
event file standing in for `debug_log`. Every claim below was confirmed twice over: the action returned
successfully **and** the app recorded that it happened.

This is the question item 12 would otherwise discover last, and it is an input to the toolkit decision
rather than a consequence of it.

### What works

| | |
|---|---|
| **AT-SPI sees a GTK3 app** | Yes -- 26 applications on the accessibility bus, the probe among them |
| **`toolkit-accessibility` does not gate it** | The gsetting reads `false` on this machine and the app was visible anyway. GTK3 loads the atk-bridge on its own; that switch is a GNOME-era control this does not depend on. **Worth knowing because the obvious first move is to turn it on**, and doing so would have credited the wrong thing |
| **Accessible name is the `AXIdentifier` equivalent** | `widget.get_accessible().set_name("probe-start-button")` comes back as the node's `name`, and a locator is one tree walk comparing it |
| **Pressing** | `queryAction().doAction(0)` on a `push button`, action named `click`. **No mouse event, no coordinates** |
| **Typing** | `queryEditableText().setTextContents(...)` on a `text` node; the app's `changed` handler fired with the new text |
| **Toggling** | `doAction(0)` on a `check box`, read back as `STATE_CHECKED` |
| **Reading for assertions** | Label text via `queryText().getText(0, -1)` -- `name` stays the identifier and the text is the value, which is the same split as `AXIdentifier` against `AXValue` |
| **While unfocused and covered** | Yes. Another window was raised over it and made active, and the press still landed. **This is the difference that matters most for the suite** |

### The tray is a D-Bus object, and that is better

**The indicator is not in the AT-SPI tree at all** -- the application node has exactly one child, the
frame. That is the same shape as the macOS status item, which `Tests/Methods.md` records as not being in
`AXMenuBar`. What differs is what replaces it: on the Mac, real mouse events through
`scripts/status-item-click.py`; here, a D-Bus object with stable ids.

```sh
# it registers itself, and the watcher lists it
org.kde.StatusNotifierWatcher -> RegisteredStatusNotifierItems
  :1.129/org/ayatana/NotificationItem/facet_probe

# the menu is a property, and com.canonical.dbusmenu reads and drives it
GetLayout(0, -1, [label]) -> id=2 Pause, id=3 Settings, id=4 Quit
AboutToShow(0); Event(2, "clicked", "", 0)   -> the app recorded: a menu item was chosen, Pause
```

`Event(4, "clicked", ...)` on *Quit* ended the process cleanly, exit 0, no window left behind. So the
whole menu-bar half of the suite is reachable without a mouse, without focus and without reading pixels
-- which on macOS costs a real `CGEvent` and a frontmost app.

**The tray label reads back too**: `XAyatanaLabel` on `org.kde.StatusNotifierItem` answered `00:00`,
which is what `StatusItemTitle` produces on the other platform. A check can assert the menu-bar clock
directly.

### What this does not say

- **It was a Python/GTK3 process.** For the one-process Swift+GTK3 candidate the bridge is GTK's work
  rather than Python's, so the same should hold -- but that is reasoning, and this file does not count
  reasoning as measurement. **Untested for Swift.**
- **Nothing was run headless.** `xvfb` is not installed and this box has no passwordless `sudo`, so
  whether the suite could run without a screen -- and therefore whether CI could ever run the Linux
  half, which it can never do for the Mac -- is open. It is the single most valuable thing to try next.
- **The screen was not locked.** Whether a locked session still answers is untested.
- **No cube was involved**, so nothing here says anything about `50`-`66`.

### Reproducing it

The four probes are not committed, being a measurement rather than an artefact. They were: put the
window and indicator up; enumerate `pyatspi.Registry.getDesktop(0)`; walk the tree comparing
`node.name`; and drive `com.canonical.dbusmenu` through `dbus.SessionBus()`. `python3-pyatspi` 2.46.1
and `at-spi2-core` 2.52.0 were already installed, and nothing was added to the machine.

---

## Found: the core runs from a real binary, and the resource bundle would ship broken

**Measured on the Linux box, 2026-09-08.** Until tonight nothing on this platform had ever *run*
`FacetCore` outside `swift test`. A 45-line executable was linked against the built core -- the first
Linux binary this project has had -- and told to do what a launch does. Four of the five answers are
good; the fifth is a fault that would have shipped.

Nothing under `Sources/` was touched to get it. The probe compiles against the objects SwiftPM had
already built:

```sh
B=.build/x86_64-unknown-linux-gnu/debug
swiftc boot_probe.swift -I "$B/Modules" -package-name timeflipapp \
  -Xcc -fmodule-map-file=Sources/SQLite3/module.modulemap \
  -Xcc -fmodule-map-file=Sources/CDBus/module.modulemap \
  $B/FacetCore.build/*.o -lsqlite3 -ldbus-1 -o boot_probe
```

`-package-name timeflipapp` is the part worth keeping: it is what makes `package` declarations visible
from outside the module, and it is the package identity lowercased, which `description.json` is where to
read off. Without it every `package` symbol is simply not in scope.

### What works

| | |
|---|---|
| **The data directory** | `.applicationSupportDirectory` answers `/home/harry/.local/share`, so the app's own path comes out as `~/.local/share/Facet/appdata.sqlite`. **No code change**: corelibs does the XDG layout, and `DebugTraceRules` already documented both |
| **The DDL through the bundle** | `ensureDatabase(at:)` with no `ddlDirectory` succeeded and applied the schema. **This path had never run on Linux** -- every test passes `TemporaryDatabase.ddlDirectory` explicitly, so the bundle lookup was untested by all 906 of them |
| **The single-instance lock** | Two real processes: the first claimed it, the second was refused `heldByAnotherInstance`. `~/.local/share/Facet/singleinstance.lock` is created on the way |
| **The keyring** | `SecretToolStore.lookUp` for an absent secret answered `missing` rather than `unavailable`, so `secret-tool` is reachable and the two cases are being told apart as designed |

### And the fault: a shipped binary dies on its resources

**`Bundle.module` on Linux is generated code with a hardcoded absolute build path in it.** SwiftPM writes
`FacetCore.build/DerivedSources/resource_bundle_accessor.swift`, and it tries two places:

```swift
let mainPath = Bundle.main.bundleURL.appendingPathComponent("Facet_FacetCore.resources").path
let buildPath = "/home/harry/git/TimeFlipApp/.build/x86_64-unknown-linux-gnu/debug/Facet_FacetCore.resources"
guard let bundle = Bundle(path: mainPath) ?? Bundle(path: buildPath) else { Swift.fatalError(...) }
```

So **on the machine that built it, every binary works wherever it is run** -- the fallback answers, and the
first probe run from `/tmp` was in fact answered by that hardcoded path rather than by anything beside the
executable. Move the same binary to a machine without that directory and it does not degrade, it dies:

```
FacetCore/resource_bundle_accessor.swift:12: Fatal error: could not load resource bundle:
from .../deploy-bare/Facet_FacetCore.resources or /home/harry/git/TimeFlipApp/.build/...
```

Measured by hiding the build directory for the length of one run. **Two things make this worse than a
missing file.** It is a `fatalError`, so `DatabaseBootstrap.Failure.ddlDirectoryNotFound` -- written
precisely for "the DDL is not where it should be" -- never gets the chance to report it, and none of the
careful error handling around it runs. And it is invisible on the build machine, which is the one place
anybody would test it.

**What it costs is one packaging rule**: `Facet_FacetCore.resources` goes beside the executable.
Confirmed working -- with the directory copied next to the binary and the build path hidden, the same
probe applied the schema without complaint. Whatever item 11 produces, its install layout has to carry
that directory, and something should check it rather than trusting it.

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
   - ~~The target, and the files into it.~~ Done. 86 files in `FacetCore`, 35 in `FacetMac`,
     `FacetCore` compiling with 0 errors and no AppKit, the DDL and `google-client.json` moved to its
     resources.
   - ~~Stage 3, the access-level loop.~~ Done 2026-09-07. **589 `package` declarations**, 152 types and
     437 members, every one of them named by the compiler.
   - ~~Stage 5, the test target.~~ Done. `@testable import FacetCore` beside `FacetMac` in 100 files,
     one target still. `ActivityIconTests` is the exception and says why in a comment: both targets
     generate a `Bundle.module`, so importing both makes every use of it ambiguous.
   - **The scripted suite has been run against the split and passed in full**, 2026-09-07 on the Mac,
     reported by the owner. **There is no stamp**: the run was a shakedown of the suite itself rather
     than evidence for the branch, it turned up several problems in the checks, and its changes were
     reverted deliberately. So the split is not what those problems were -- the fixes are in
     `Tests/Scripted/lib.sh`, `51-device-connect.sh`, `53-device-reconnect.sh` and `56-manual-mode.sh`
     (`4bb6ff5`, `21a55b1`, `0f78510`), all of them about how a check waits rather than about what the
     app does.

     **CI is still red and correctly so.** The committed stamp is run 170 at `0f78510`
     (`outcome: failed`, 11 scripts short), and twelve files have changed since -- the timezone seeding,
     `TimezoneStore`, and the suite's own fixes. Clearing it needs a full run committed as a stamp,
     which needs a cube and a person.

   The `#if canImport(AppKit)` fallback was not needed and is now moot.
3. ~~**Platform-aware data directory.**~~ **Done 2026-09-07, Mac.** The seeded `debug` row named
   `~/Library/Application Support/Facet`, which is the wrong folder on Linux and sat in DDL both
   platforms share. It seeds `directory` as an **empty string** now, and empty means the folder the app
   already keeps its databases in: `DatabaseBootstrap.debugDatabaseURL(in: nil)` was already asking
   `FileManager` for it, and `DebugTraceRules.directoryURL` already answered `nil` for empty so the
   caller could decide what empty meant. `DebugTraceRules.defaultDirectory` is computed from
   `applicationSupportDirectory` rather than written down, so it is the right folder on either platform.

   The claim this item used to make, that the literal was in four source files and 10 test files, was
   wrong: three of the four only mention it in doc comments and already call `applicationSupportDirectory`.
   See the layer-boundaries section.

4. ~~**The three Foundation gaps** above.~~ **Done 2026-09-07, Mac**, all three no-ops on macOS.
   `#if canImport(FoundationNetworking)` in the three files that use `URLSession`, 28 uses.
   `abbreviatingWithTildeInPath` written out by hand in `DebugTraceRules.stored`, with tests for the two
   edges the API gave for free: the home directory itself abbreviates to `~`, and a sibling whose path
   merely starts with the home path is not inside it. **`setvbuf` is guarded to Darwin rather than
   solved** -- glibc's mutable `stdout` is still refused by Swift 6, so a Linux terminal loses the
   immediacy of the printed copy while `debug_log` still gets every row, which is the half the scripted
   checks read.
5. ~~**Make `DatabaseBootstrap` refuse an empty DDL listing**, and resolve symlinks before
   enumerating.~~ Done 2026-09-06, along with flipping `database/` to be the real directory.
6. **Migrate the test suite to swift-testing**, checking every `tearDown` by hand for the `deinit`
   isolation trap. **Reopened and mostly cleared on 2026-09-09: four of the six migrated, worth 93 tests,
   and the last two are blocked by something a migration cannot fix.**

       migrated, and running here:  DeviceEventRecorderTests 35 - FaceColourSyncTests 22
                                    TimeEntryRecorderTests 18 - DeviceSettingsSyncTests 18
       still excluded, 17 tests:    LowBatteryWatchTests 10 - WriteDebounceTests 7

   The two that are left need the main thread's run loop, and on Linux a `@MainActor` swift-testing test
   does not run on the main thread -- measured, with the probe and the consequences, in *`@MainActor` is not
   the main thread* above. **So this item is finished except for a decision that is not a migration**:
   whether the two subjects should take their `RunLoop` as a parameter. Until that is agreed, 17 tests stay
   off this platform and `Package.swift`'s `mainRunLoopTests` says why.

   With the four in, Linux runs **1,049 tests**: 590 under XCTest and 459 under swift-testing, 0 failures.

   **The claim below that the `mainActorTests` list was gone because it emptied was wrong**, and wrong in
   a way worth keeping: it emptied of the files anybody was looking at. These six were sitting on
   `platformBoundTests` at the time, which is the list for things that cannot run here at all, so the
   migration never saw them as candidates -- it emptied its own queue while six migratable suites hid on
   the other list. Every one of them tests a `FacetCore` module and uses no AppKit, no CoreBluetooth and
   no `FacetMac` type; each is a `@MainActor` `XCTestCase` subclass, which is the case that aborts the
   whole run at load time rather than failing on its own. Migrating a file is the whole of what moves it
   off the list.

   **So the sentence below about the 48 is wrong twice over.** There are 44 now, and they are not all
   excluded for a platform: 38 need AppKit, CoreBluetooth or a `FacetMac` type, and 6 are these, waiting
   on exactly this item. `Package.swift` carries both lists separately for that reason -- a list of
   exclusions that does not say which of two reasons it is will absorb the other.

   **Done for everything that can run here, 2026-09-07, Linux.** All 17 portable
   `@MainActor` suites are on swift-testing, the `mainActorTests` exclusion list is gone because it
   emptied, and **873 of the 1725 tests pass on Linux**: 333 under swift-testing in 45s beside 540 still
   under XCTest in 1.9s. Both figures were superseded the same day: `systems-info.md` recorded 906, from
   366 under swift-testing, and 956 run there as of 2026-09-09.

   The 48 files still excluded are excluded for needing AppKit, CoreBluetooth or a `FacetMac` type, not
   for their testing framework, and they migrate when their platform arrives.

   **Under way. 14 suites migrated, and 832 of the 1725 tests now run on Linux** (2026-09-07): 292
   under swift-testing in 42s, beside 540 still under XCTest in 2s. 17 files are left on the
   `mainActorTests` list, three of them for a reason worth knowing -- see below.

   The structure it needed came first, and what made it possible was not the migration but getting the
   package to build tests at all on Linux:

   - `FacetMac` is no longer in the package on Linux, and neither is the executable product. `swift test`
     builds *every* target rather than only what the tests depend on, so a declared AppKit executable
     killed every run.
   - The test target's dependencies are chosen by the host rather than carrying `.when(platforms:)`.
     **SwiftPM resolves a dependency by name before it applies the condition**, so merely *naming*
     `FacetMac` from the test target made it hunt for sources that are not there and fail the manifest.
   - `Package.swift` carries two lists of test files to exclude on Linux, with the reason attached to
     each: **48 platform-bound** (AppKit, CoreBluetooth or a `FacetMac` type) and **17 `@MainActor`
     XCTestCases**. The second list is this item's work queue, 333 tests, and it shrinks as they migrate.
     An isolated *helper* is not affected and is not listed -- only an XCTestCase subclass aborts a run.
   - 36 files stopped importing `FacetMac`, and one carried a vestigial `import AppKit`
     (`DeviceFaceRulesTests`). Neither was needed; the Linux build is what proved it, since a file that
     compiles without a module needs nothing from it on either platform.

   **What the mapping table above does not mention, and each cost a compiler round to find:**

   - **`Testing` does not re-export Foundation** the way `XCTest` did. Seven files needed
     `import Foundation` added.
   - **`deinit` can do the cleanup, but only what needs no isolation.** It is never isolated, so
     reading an isolated `var` from it is refused -- the `database` property becomes a `let`, and
     `TemporaryDatabase` being a `Sendable` struct with a nonisolated `remove()` is what makes the rest
     work. The `x = nil` lines the old `tearDown` bodies carried simply go: the instance is discarded
     whole. Verified it still cleans up, with zero temporary directories left after a run.
   - **`try` is fine at the start of an `#expect` and illegal to the right of an operator.**
     `#expect(try #require(a).isActive)` compiles; `#expect(a < try #require(b))` does not, and those
     three call sites were hoisted to locals.
   - **`#expect`'s message is a `Comment`**, which a string *literal* becomes on its own. A `String`
     expression -- a concatenation, say -- does not, and has to be interpolated.
   - **`accuracy:` has no equivalent**, `#expect` taking one expression rather than a pair. The six
     colour-channel comparisons went through a named `isApproximately` so the tolerance stays visible.

   **The three files whose `tearDown` did isolated work turned out to need one decision each**, and the
   answers are worth having because none was a rewrite:

   - `HistoryTimerTests` called `built?.stop()`, which a `deinit` cannot. **It does not need to**:
     `HistoryTimer` keeps its `Timer` in a `TimerHolder` whose own `deinit` invalidates it, a shape that
     type adopted for this exact reason and documents. Releasing the suite releases the timer, which
     stops itself, so the `stop()` was belt and braces.
   - `DevicePINSourceTests` removes a directory, which needs no isolation at all -- a `URL` is
     `Sendable` and `FileManager` does not care who asks.
   - `DebugTraceFileTests` was the ordinary case written on one line, which the pattern pass missed.

   **Two differences with teeth, found by running rather than reading:**

   - **XCTest assertions absorb a thrown error and `#expect` does not.** Their arguments are throwing
     autoclosures, so `try` inside one never needed the test to be `throws`. Hoisting an unwrap out of a
     comparison makes the test `throws`, and the compiler is the one that says so.
   - **`.immutable` is a BSD file flag corelibs does not implement**, and a `try?` around it swallowed
     the refusal -- so a test asserting that a file which will not give up its copy is not reported as
     settled *failed on Linux against an app behaving correctly*. The portable equivalent is taking
     write permission off the file (`0o400`), and it had to be the **file** rather than the directory
     because `DeveloperConfigFile.clearPIN` rewrites in place, deliberately not atomically -- an
     in-place write needs no permission on the containing directory at all.

   **One difference to know about rather than fix: cleanup is no longer deterministic.** XCTest called
   `tearDown` itself; swift-testing's equivalent is `deinit`, which runs when ARC says so, and at process
   exit some instances are never released at all. A full run leaves a dozen or so `facet-db-*`
   directories in `/tmp` where XCTest left none. Harmless -- they are temporary directories in the
   temporary directory -- but it is the sort of thing somebody would otherwise go hunting for.
7. ~~**`Security` to libsecret.**~~ **Done 2026-09-07, Linux, and not via libsecret.** Both stores
   branch at compile time inside their own four functions, as this item said they would, so no call site
   changed and the Darwin bodies are untouched.

   **libsecret's simple API turned out to be uncallable from Swift**: `secret_password_store_sync` and
   friends are variadic C (measured against the installed header). In-process means the `*v_sync`
   variants, which take a `GHashTable`, which means a second system-library target for glib-2.0, a
   `SecretSchema` built by hand and GError plumbing -- around 200 lines and a new class of memory bug
   against 60 for `secret-tool`. `SecretToolStore` carries the reasoning, and the swap back is entirely
   inside that one file if packaging ever objects to depending on a binary.

   **The thing that had to be right: an exit code is not the answer.** `secret-tool` exits 1 both for a
   secret that is not there and for a keyring it cannot reach, so an empty stderr is what tells them
   apart. Collapsing them is the fault `DevicePINStore.Lookup` exists to prevent -- the app would rotate
   the PIN of a cube whose perfectly good PIN it merely could not read.

   Verified against this machine's real keyring, twelve checks including byte-exact round trips, a
   secret with trailing newlines, unicode, and `missing` rather than `unavailable` for an absent item.
   The hermetic suite cannot cover any of it until item 6.

   **Groundwork kept**: both `Lookup` enums answer `unavailable(Int32)` rather than `OSStatus`, which is
   the same type on Darwin and exists everywhere.

8. ~~**`CryptoKit` to swift-crypto.**~~ **Done 2026-09-07, Linux, and not with swift-crypto.**
   `PortableSHA256` is 60 lines in the core; Darwin keeps CryptoKit and only Linux calls it. The
   dependency was refused because `Package.swift` states it has none and the archived app's one
   dependency was dropped for the same reason -- and because what is hashed is a public random string
   whose wrong answer Google rejects at once. **It is compiled on both platforms and called on one**, so
   the Mac's `swift test` covers the code Linux depends on, including a case asserting the two
   implementations agree at every length from 0 to 200. Verified against published vectors, `sha256sum`
   over 201 inputs, and `hashlib` at the twelve lengths where the padding changes shape.
9. ~~**`Network` to a plain socket listener.**~~ **Done 2026-09-07, Linux.** `GoogleLoopbackListener`
   moved out of `GoogleOAuthClient` into `FacetCore` and now has two halves behind one interface:
   `Network` where there is `Network`, Berkeley sockets where there is not.

   **The Darwin half moved across unchanged**, deliberately. It is the path a real sign-in has used, and
   there was nothing to gain on that platform by rewriting it in sockets for the sake of having one
   implementation -- the same reasoning as items 7 and 8.

   What made the file portable enough to live in the core was taking the listener *out* of
   `GoogleOAuthClient`, whose whole remaining tie to AppKit is **one default argument**:
   `NSWorkspace.shared.open`, for putting a URL in front of a browser. That file stays on the platform
   side and now says so at the top. A Linux equivalent is `xdg-open` through `Process`, and it belongs
   with whatever starts a sign-in rather than here.

   Three things the socket half had to get right, none of which the `Network` version shows:

   - **`poll` with a timeout rather than a bare `accept`.** Closing a descriptor that another thread is
     blocked in `accept` on does not reliably wake it on Linux, so the loop asks whether anything is
     waiting and checks between asks whether it has been told to stop.
   - **`bigEndian` rather than `htons`**, which is a C macro Swift cannot call. Same for the loopback
     address, written as `0x7f00_0001` byte-swapped.
   - **`SO_REUSEADDR`**, which is what `NWParameters.allowLocalEndpointReuse` asks for on the other side:
     a port left in `TIME_WAIT` by the previous sign-in must not refuse this one.

   **Both halves are covered by the same five tests** (`GoogleLoopbackListenerTests`), which drive
   whichever one they got over a real loopback connection the way a browser would: a port is assigned and
   two listeners get different ones, a code arrives and the browser is left looking at the right page, a
   refusal arrives as `denied`, a `/favicon.ico` request and a mismatched state leave the listener still
   waiting, and `cancel` settles whoever is waiting. That last-but-one is the case that actually broke a
   sign-in once. Mutation-checked rather than assumed: the code assertion was pointed at a wrong value
   and the test failed, so it is really talking to a socket.
10. **The BlueZ backend in Swift.** Roughly 600-1000 lines behind the interface `BluetoothRadio` already
   presents. `scripts/linux-ble-probe.py` is the working reference for every D-Bus call it needs -- and the
   whole of what it needs is **11 methods and 2 signals**: `GetManagedObjects`, `Get`/`GetAll`/`Set`,
   `StartDiscovery`, `StopDiscovery`, `Connect`, `Disconnect`, `ReadValue`, `WriteValue`, `StartNotify`,
   `StopNotify`, with `PropertiesChanged` and `InterfacesAdded` to listen to.

   **Groundwork done 2026-09-07, Linux**: `TimeFlipUUIDs` is in the core now, its `CBUUID` accessors
   split off into `TimeFlipUUIDs+CoreBluetooth.swift` beside the radio. What is portable about a UUID is
   its string, and there is one real difference between the platforms in it: **the vendor's table lists
   the seven standard UUIDs in 16-bit shorthand, CoreBluetooth accepts them that way, and BlueZ never
   uses the shorthand at all** -- it reports `0000180f-0000-1000-8000-00805f9b34fb` for what this app
   calls `180F`. `TimeFlipUUIDs.canonical(_:)` and `match(_:_:)` are that expansion, checked against the
   spelling BlueZ prints on this machine. Without it every characteristic lookup would find nothing,
   silently.

   ### What is built so far

   | Piece | What it does | Checked by |
   |---|---|---|
   | `SystemBus` | the whole of the libdbus interop: calls, marshalling both ways, signals | 7 tests against the real system bus |
   | `DBusValue` | a D-Bus value as a plain Swift tree, so nothing above sees libdbus | the above, plus every tree test |
   | `BlueZObjectTree` | the object tree read as records: adapters, devices, services, characteristics | 9 tests, hand-built trees |
   | `BlueZAddress` | a Bluetooth address carried inside the `UUID` this app is written around | 6 tests, both directions |
   | `TimeFlipUUIDs` | the UUID strings, and the 16-bit expansion BlueZ needs | 6 tests |
   | `BlueZRadio` | power, discovery, connect, disconnect, forget | run against the real cube |
   | `BlueZGatt` | read, write, subscribe, and the value out of a signal | run against the real cube |

   **Everything above `SystemBus` is pure**, which is deliberate: the mistakes this layer makes are silent
   ones. A UUID compared in the wrong spelling finds no characteristic and reports nothing missing, and a
   property read without unwrapping its variant answers an empty array -- **which is a bug that happened**,
   caught by a test rather than by a run: BlueZ wraps every property in a variant, so `Flags` and `UUIDs`
   came back empty until `DBusValue.items` learned to see through one.

   **Two decisions worth knowing about:**

   - **A Bluetooth address is carried inside a `UUID` rather than widening the model.** `ScannedDevice`,
     `CubeRadio` and the `device_uuid` row are all written in terms of a `UUID`, and BlueZ has no such
     identifier -- it has the device's real address. So the six address bytes go in the last six bytes of a
     UUID behind a constant marker (`face7000-0000-0000-0000-…`), which is deterministic in both
     directions: the same cube is the same identifier on every launch and the address reads back out to
     make a call with. The marker is *checked* when reading, so a `device_uuid` written on the Mac -- a
     perfectly valid UUID naming nothing here -- is refused rather than aimed at six bytes of somebody
     else's identifier.
   - **Which advertisement is a cube is `DeviceScanRules`, unchanged.** The same rule CoreBluetooth's side
     asks, so a renamed cube is found or lost identically on both platforms rather than by two rules that
     have to be kept in step. Writing the probe for this taught its own lesson: `ordered` is *ordering, not
     filtering*, as its comment says, so taking its first element answers an arbitrary device when nothing
     is eligible at all. `isEligible` is the filter.

   ### What the cube itself answered, 2026-09-07

   The sequence in full, from `FacetCore`'s own code over libdbus with no subprocess: discovery found the
   cube by `DeviceScanRules`; connect gave `ServicesResolved: true` and `Paired: false`; **16
   characteristics** resolved, every one the app names matched from the app's own spelling -- which is the
   16-bit expansion earning its keep; the vendor PIN went on the wire as six ASCII digits and the command
   result read back `02`; `DI_LABS`, `2.0`, `FW_v3.64`, battery `100%`, facing `0c` came back off real
   reads; and notifications arrived as `PropertiesChanged` signals carrying `ay`, read as `[UInt8]`.

   **The address survived the factory reset** -- `E8:DB:D8:CF:F9:0F` before and after -- which
   `systems-info.md` had down as untested, and which matters because it is a *random*-type address, the
   kind the specification lets a device change.

   **Then the face turns, confirmed the same evening.** A passive listen caught **ten pushes over seven
   distinct faces** (`01, 04, 05, 08, 09, 0b, 0c`) as the cube was turned by hand. And the `0x10` status
   read went out, its answer parsed by the app's own `DeviceCommandRules`: not locked, paused, auto-pause
   5 minutes, off a cube fresh from a factory reset. So the read-back discipline `CLAUDE.md` requires is
   available on this platform, through the same parser the Mac uses.

   **Still unwritten: anything but the PIN and `0x10`.** No pause, no lock, no colour, no task parameters.

   **Three things measured on the way that were not in the notes**, all now in
   [linux-bluez-port-notes.md](linux-bluez-port-notes.md):

   - **A `ReadValue` publishes a `PropertiesChanged` of its own**, so a read and a device push cannot be
     told apart at the signal level. Found the hard way: a probe polling `faces` once a second produced 39
     signals that all looked like notifications and were its own doing.
   - **`le-connection-abort-by-local` is a transient**, answered when a `Connect` comes a few seconds
     after disconnecting the same cube, and the next attempt succeeds. `BlueZRadio` retries it four times
     and throws everything else -- it matters because a reconnect is precisely when it happens.
   - **Two strings on the events data characteristic that are not in the recorded table.** That it carries
     ASCII is in the vendor spec and finding 3 enumerates a table of them -- this was written up as a
     discovery on first pass and was not one. What is new is `password OK` on a correct login and
     `New Side: 0x00` on every face change, neither of which is in that table, and the side number is
     always `0x00` whichever face it is.

   And **finding 4 holds through a second stack**: `0x02` on the command result means a correct PIN, not
   the `0x01` the spec promises. Finding 4 measured that over CoreBluetooth in August; this measured it
   over BlueZ and libdbus. Two hosts, two Bluetooth stacks, the same inverted byte -- which is worth
   having, because that byte decides whether the right cube is let in.

   **Neither `BlueZRadio` nor `BlueZGatt` has a hermetic test**, and cannot: both are I/O against a daemon
   and a device. The suite covers everything they are built on -- the bus, the value tree, the object tree,
   the addresses, the UUIDs -- and what covers these two is a device run, which is what `Tests/Scripted/`
   is for once there is an app on this platform to drive.

   **Still unverified and first on the list**: the two-name mapping. On Darwin the advertised local name
   never changes while `CBPeripheral.name` is the GAP name a rename moves (finding 1, seven renames). BlueZ
   has `Name`, the remote device's own, and `Alias`, a *local* override defaulting to it -- so `Name` is the
   closer analogue of both, and **whether a `0x15` rename moves it has not been measured**. `BlueZRadio`
   says so at the mapping.

   ### The transport is decided: libdbus, in process

   **`SystemBus` in `FacetCore` is the whole of the C interop, and nothing above it sees libdbus.** It
   answers `DBusValue`, a plain Swift tree, so the BlueZ layer will be written against Swift values.

   `CDBus` is a `systemLibrary` target over `dbus/dbus.h`, Linux-only in the graph exactly as `SQLite3`
   is. **`pkgConfig: "dbus-1"` is load-bearing rather than tidy**: libdbus needs *two* include
   directories, the arch-dependent `dbus-arch-deps.h` living under `/usr/lib/<triple>/dbus-1.0/include`
   while the rest is in `/usr/include/dbus-1.0`.

   **What made it possible is that none of the API this app needs is variadic.** `dbus_message_append_args`
   is, and would have been uncallable from Swift exactly as libsecret's simple API turned out to be
   (item 7) -- but the `dbus_message_iter_*` family that replaces it is not, and that family is all of it.

   **One thing the importer cannot read**: the type constants are `#define DBUS_TYPE_STRING ((int) 's')`,
   a cast it does not follow, so `SystemBus.Kind` spells them out by value.

   Proven against the real bus, seven tests: a call answering `as`, a string argument going out and a
   boolean coming back, a refusal keeping its D-Bus error name (`org.bluez.Error.NotConnected` says what a
   message string does not), the nested `a{oa{sa{sv}}}` object tree walked to the adapter's `Address`, a
   byte array and an options dictionary marshalled cleanly enough that BlueZ refuses the *object* rather
   than the arguments, and a `PropertiesChanged` signal arriving with `Discovering` as a boolean inside a
   variant. That last one triggers its own signal by toggling discovery, so it needs nothing in range.

   **A caller filters signals by what it asked for**, because not everything arriving is a match hit: the
   bus sends `NameAcquired` to a new connection whatever it has subscribed to. Measured, not assumed.

   ### What was measured before deciding, kept because it is what the decision rests on

   | Route | Works? | Cost |
   |---|---|---|
   | **`busctl` subprocess** for method calls | **Yes.** `busctl --system --json=short call org.bluez / …GetManagedObjects` returns type-tagged JSON a `JSONDecoder` reads, and the awkward `WriteValue` shape (`aya{sv}`) parses | Nothing to install |
   | **`busctl monitor`** for signals | **No. Refused unprivileged**: `BecomeMonitor` answers `Access denied` on the system bus | -- |
   | **`gdbus monitor`** for signals | **Yes**, unprivileged -- it adds match rules rather than becoming a monitor, and streamed real `PropertiesChanged` from `org.bluez` including the cube at RSSI -62 | Emits GVariant **text**, not JSON, so a notification value arrives as `{'Value': <[byte 0x38, 0x00]>}` and needs a parser of its own |
   | **`libdbus-1` with a modulemap** (the `SQLite3` pattern) | Untried | Needs `libdbus-1-dev`, which is **not installed** -- only the runtime `libdbus-1-3` 1.14.10. Its simple append API is variadic and so uncallable from Swift, but the `dbus_message_iter_*` API is not |
   | **The D-Bus wire protocol in Swift** | Untried | No dependency at all, and the most work: SASL EXTERNAL, then marshalling, including reading `a{oa{sa{sv}}}` |

   **What decided it was where the notification values are read.** Face turns arrive as signals carrying a
   byte array, which is the app's core function, and every subprocess route leaves that path depending on a
   parser of human-readable output -- `{'Value': <[byte 0x38, 0x00]>}` picked apart by hand. libdbus hands
   the same bytes over typed. That is the opposite conclusion to the keyring's in item 7, and for a
   consistent reason: there the subprocess won because the swap was contained in one file and the values
   were strings; here the values are the point.
11. **The UI.** **The toolkit is decided and the first two slices are done**: Swift calling GTK3 and the
    Ayatana indicator through `Sources/CGtk`, which is a `systemLibrary` modulemap exactly as `SQLite3` and
    `CDBus` are, so it is one process and one language and no Swift bindings to keep in step with. What
    exists is `Sources/FacetLinux` -- the boot, and a menu bar item whose one working control is Quit. What
    is left is the rest of it: the timing readout in the label (`TimingReadout` is already in `FacetCore`,
    and the label carries a `00:00:00` guide for it), the Settings window and its five tabs, and the Report
    tab. Those are the 31 AppKit files, and they are the bulk of the port.
12. **The scripted suite on AT-SPI.** The largest single piece, and the only thing that can say the app
    works. `Tests/Methods.md` techniques survive; the locator layer is new. **The mechanism is no longer a
    question** -- the section above drove a GTK3 window and an AppIndicator menu end to end, including
    while the window was covered and unfocused, so what is left here is the locators and the checks
    rather than whether either can be addressed at all.
13. **Repo restructure and the `CLAUDE.md` split.** Agreed: one repo, shared core. About a third of the
    root `CLAUDE.md` is AppKit-specific and would be worse than noise in a GTK session. **The
    `database/` symlink is no longer part of this item**: it used to point into the macOS bundle
    resources and was flipped in `7ade2c7`, so `database/` is the real directory and the path under
    `Sources/` is the link. Nothing about the restructure waits on it any more.
14. **README.** Links this file from its docs list, and otherwise still describes a macOS-only project.
    Rewriting it to describe two platforms waits for item 13, rather than being half-applied now.

## To check

Open questions, with what would answer each.

| Question | How to answer it |
|---|---|
| ~~**Does the core build on Swift 6.0?**~~ **Withdrawn: the premise was wrong.** It was asked because this file believed the Mac built with 6.0, read off `swift-tools-version: 6.0`. That line is the manifest and language level, not the compiler. The Mac builds with **6.3.3**, Linux used **6.2**, and no machine has 6.0 or wants it. `docs/installation.md` states 6.0 as a **minimum**, which both satisfy | Retired 2026-09-07, Mac. Nothing needs a 6.0 toolchain; if the stated minimum is ever worth proving, that is a release question about `installation.md`, not a port question |
| **Do the other 61 test files pass?** They were excluded for referencing types outside the closed set, not for failing | Widen the closed set as `FacetCore` takes shape |
| **Does Darwin hand back a `TZ` that corelibs refuses?** `TimeZone.current.identifier` echoes a legacy IANA name verbatim on both platforms (`TZ=Cuba` answers `Cuba`), which is why `timezone` is seeded and read through `timezone_lookup`. But `TZ=AEST` is **refused** on Linux and falls back to the system zone, while an `AEST` row reached the Mac's `test.sqlite` somehow. A behavioural difference in a Foundation call the app depends on | Question 4 in [systems-info.md](systems-info.md), where the answer lands |
| ~~**How many `tearDown` methods hit the `deinit` isolation trap?**~~ **27 of 30.** Measured on the Mac 2026-09-07 by brace-matching each `tearDown` body: 27 wrap their work in `MainActor.assumeIsolated` and would trap in a `deinit`; 3 do not. It never needed Linux to answer, being a property of the test sources | Answered 2026-09-07, Mac |
| **Is `contentsOfDirectory(at:)` on a symlink a known corelibs bug or intended?** Worth reporting upstream if the former. **Narrowed 2026-09-07, Linux**: it is specific to a symlinked *directory*. A symlinked **file** inside a real directory is listed by both `at:` and `atPath:` and read straight through by `String(contentsOf:)` -- measured on `database/500_timezone.sql`, 13 of 13 `.sql` files found either way. So a report has a smaller and sharper case than the original finding suggested | Check the swift-corelibs-foundation tracker |
| ~~**Does SwiftPM follow the symlinked resources directory on macOS?**~~ **Yes**, before and after the split: 13 `.sql` files in the built bundle, flattened to its root | Answered 2026-09-06, Mac |
| ~~Does `Thread.isMainThread` matter?~~ **No.** It reads `false` inside a `@MainActor` test on Linux -- isolation holds, the OS thread simply is not thread 1 -- and nothing in `Sources/` calls it | Answered 2026-09-06 |
| ~~**What do the 41 platform files actually need?**~~ **35 of them, and now assessed by the compiler.** `FacetMac` is what did not move: the panes and views, `BluetoothRadio`, `DeviceLogin`, `BLETrace`, `TimeFlipUUIDs`, `MenuBarController`, `MainMenu`, `ActivityIcon`, `GoogleOAuthClient`, `QuitSequence`, `StatusItemTitle`, `ColourDrawing` and `main.swift` | Answered 2026-09-06, Mac |
| ~~**How many members does stage 3 actually have to widen?**~~ **437 members, over 152 types, 589 `package` declarations in total.** The loop was run and the section above carries the working; the type count of 94 this row quoted was low by more than half, because what the compiler asks for is the types `FacetMac` names *plus* everything that comes with them | Answered 2026-09-07, Mac |
| ~~**Does the scripted suite still pass after the split?**~~ **Yes, in full**, reported by the owner from a shakedown run on the Mac. Not a stamped run and not evidence for CI, which still wants one -- but it answers the question this row was asking, which was whether moving `Sources/` wholesale had broken the app on hardware. It had not | Answered 2026-09-07, Mac |
| **Does the rename apply immediately or is it deferred?** Open since August; finding 1 wants a second BLE central with no cached record, and this box is one | Rename from the Mac, read the GAP name from Linux |
| **Does the `T.Flip` manufacturer data survive a rename?** If it does, a renamed cube has two stable markers | Rename, then re-read `ManufacturerData` |
| **Is the static random address stable across a power cycle or factory reset?** The BLE spec permits it to change | Pull the batteries, re-scan, compare |
| **Does the Google OAuth loopback flow work on Linux?** The listener is replaceable, but the flow is untested end to end | After item 7, with a real Google account |
| **What is the state of Swift GTK3 bindings?** MATE 1.26 is GTK3, and the binding work known to exist targets GTK4 | Survey before committing to a single-process design |
| **Does `swift build` work with real `libsqlite3-dev`?** The spike used a hand-written 25-symbol header | Install the package and drop the shim |

## Decided: CI tests both platforms, and everything on each

**Decided 2026-09-09. Every test runs in CI, on every platform that can run it.** Not the Mac's suite with
Linux checked by hand, and not a Linux job that runs only the Linux-specific parts -- the whole suite, twice,
each platform running as much of it as it can.

**Why both, when most of the tests are the same tests.** Because the overlap is the product rather than the
waste. There is no `#if os(Linux)` anywhere in `Sources/` and exactly **7** of the tests are Linux-only, so a
plan of "test everything on the Mac, test the Linux-only parts on Linux" would cover 7 tests and leave 1,042
running against one Foundation only. Those 1,042 are where both platform divergences found so far actually
lived: a `Timer` on `RunLoop.main` that never fires because a `@MainActor` swift-testing test is not on the
main thread here, and `FileManager.contentsOfDirectory(at:)` returning an empty array for a symlinked
directory where Darwin follows it -- which `DatabaseBootstrap` reported as a database created successfully.
Both are shared code passing on one platform and failing on the other. Running one test against two
Foundations asks two different questions, so coverage is a property of test x platform rather than of the
test list.

### Where it stands, and what each number is waiting on

| | Tests | |
|---|---|---|
| Every test in the repository | **1,758** | 1,751 the Mac can run, plus the 7 Linux-only |
| macOS CI runs | **1,751** | everything that platform can run |
| Linux CI runs | **1,047** | the 1,042 the Mac also runs, plus 5 of the 7 Linux-only |
| Linux-only, skipped in CI | **2** | the two needing a real BlueZ adapter, below |
| Mac-only, not yet on Linux | **709** | the 40 files `Package.swift` excludes |

**The 709 close as the port lands**, and they are already itemised rather than estimated: 38 files need
AppKit, CoreBluetooth or a `FacetMac` type and come back with items 9, 10 and 11, and 2 need the main
thread's run loop, which is a decision rather than work -- whether `WriteDebounce` and `LowBatteryWatch`
should take their `RunLoop` as a parameter. Nothing else is excluded, and the manifest says which of the two
reasons each is.

**Only 2 of the 7 are really hardware-bound, and that is measured rather than reasoned.** The job skipped
the suite whole to begin with. It was settled on 2026-09-09 **without a container**, which is the part worth
keeping: `SystemBus.init` calls `dbus_bus_get(DBUS_BUS_SYSTEM)`, libdbus reads `DBUS_SYSTEM_BUS_ADDRESS`, so
a private `dbus-daemon` on any machine reproduces a runner's bus -- one with no BlueZ on it -- and the suite
can simply be pointed at it.

| Test | Needs | On a bus with no BlueZ |
|---|---|---|
| `theSystemBusCanBeReached` | a system bus | **passes** |
| `aCallAnswersAnArrayOfStrings` | a system bus | **passes** |
| `aStringArgumentIsSentAndABooleanComesBack` | a system bus | **passes** |
| `arefusalCarriesTheErrorName` | a system bus | **passes** |
| `aByteArrayArgumentIsAcceptedByTheWire` | calls `org.bluez`, asserts a **refusal** | **passes**, and see below |
| `theNestedObjectTreeIsWalkedToItsLeaves` | a real BlueZ **adapter** | fails, `Issue.record` at `:96` |
| `aSignalArrivesAndItsValuesAreTyped` | a real BlueZ **adapter** | fails, `Issue.record` at `:166` |

So five run in CI and two cannot run on any runner, belonging with `Tests/Scripted/`: their absence is a fact
about the machine rather than about the code.

**`aByteArrayArgumentIsAcceptedByTheWire` passes for a different reason in CI than on a developer's box**,
which was the thing worth settling before counting it. It asserts only that the call is refused, and both
conditions refuse:

    no BlueZ      org.freedesktop.DBus.Error.ServiceUnknown   -- the bus, because nothing owns the name
    BlueZ present org.freedesktop.DBus.Error.UnknownObject    -- BlueZ, about the object path

In CI it therefore proves libdbus marshalled the byte array and put it on the wire, which is its stated
claim, but it stops at the bus and proves nothing about what BlueZ accepts. Counting it is defensible on that
reading. Asserting *which* error would make it honest on both machines and is the obvious improvement, but it
changes what the test claims, so it is noted here rather than done.

### What is left to do for this plan

1. ~~**Start a system bus in the Linux job** and narrow the skip to the adapter-bound tests.~~ **Done
   2026-09-09.** The job writes a `dbus-daemon` config, starts a private bus, exports
   `DBUS_SYSTEM_BUS_ADDRESS` through `GITHUB_ENV` and skips exactly two tests by name. Verified by running
   both steps as YAML hands them to the shell: **1,047 tests, 0 failures**, 590 under XCTest and 457 under
   swift-testing, against a bus with no BlueZ. That is 5 more than the 1,042 the plan started with rather
   than the 4 it predicted, `aByteArrayArgumentIsAcceptedByTheWire` turning out to pass -- for the reason
   set out above, which is not the reason it passes on this box.
2. **Take the run-loop decision**, worth 17 tests, and either way write it down: injecting the `RunLoop` is a
   production change made for a test's benefit, and `RunLoop.current` would only work by coincidence.
3. **Let items 9, 10 and 11 return the other 38 files** as sign-in, the radio and the UI arrive on this
   platform. Each one should take files off `platformBoundTests` in the same change, rather than leaving the
   list to be audited later.
4. **Keep the two compilers comparable, or know that they are not.** The job declares `swift:6.2-noble`,
   which floats within the 6.2 line and was 6.2.4 when checked, where this box is on 6.2.0. A CI-only failure
   should be checked against that difference first.

**A note on how this was worded before, because the wording was the fault.** `systems-info.md` recorded
*nothing in CI compiles the project on Linux today* as a fact, dated and accurate, sitting in a table of
facts. It was true and it was the wrong shape: a gap stated in the indicative reads as a condition to work
around, where the same thing put as a question -- should CI run the Linux tests as well? -- gets answered in
an afternoon. It had been true for a month. Where this file records something the port cannot do yet, it
should say what would close it and whose call that is, which is what the four items above are for.

## Decided: one process, Swift calling GTK3 through a modulemap

**Settled 2026-09-09 by the owner, and the first two slices are built.** The candidates were one process in
Swift + GTK3, or two processes with a Python/GTK3 tray over SQLite as the IPC; this file recommended the
second on the grounds that Swift GTK *bindings* target GTK4 while MATE is GTK3.

**What retired that risk is that no binding is involved.** `Sources/CGtk` is a `systemLibrary` target over
the system's own GTK3 and `libayatana-appindicator3`, which is the pattern this package already uses twice
-- for `SQLite3` and for `CDBus` -- so there is nothing to keep in step with anybody's release schedule.
The awkwardness C imposes is real but small and already answered: GTK's casts and `g_signal_connect` are
macros, which Swift's importer leaves behind, so three `static inline` helpers in `shim.h` do them in C
where the macro works and the type check survives.

**What the two-process design would have cost, now that it is not being paid**: a second language, a second
process for `Tests/Scripted/` to launch and quit, `InstanceLock` becoming per-process rather than per-app,
and care over WAL mode with a busy timeout. `platform.sh` assumes one `BINARY`, and it is right to.

It needed `libgtk-3-dev` and `libayatana-appindicator3-dev`, which `Package.swift` names in the target's
`providers` so the next machine is told rather than left to work it out.

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
