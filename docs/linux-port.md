# The Linux port

[← Back to README](../README.md) · [BlueZ notes →](linux-bluez-port-notes.md) · [The ports plan →](architecture-ports-plan.md) · [FacetCore split →](facetcore-split.md) · [The two systems →](systems-info.md)

**The living status of running Facet on Linux.** What has been established, what is left to do, and what is
still an open question. Every claim here is either marked as measured -- with the date and the machine -- or
marked as untested. Nothing in between, because the whole value of this file is that somebody can tell the
difference without re-running the work.

**Keep it current in the same change that changes the answer.** A finding that lands without this file moving
is a finding that will be measured twice.

**The to-do numbers are addresses and are never reused.** `Tests/Scripted/platform.sh`, `run.sh`, `lib.sh`,
`scripts/check_interactive_checklists.sh`, `Sources/FacetLinux/SecretToolStore.swift`, `facetcore-split.md` and
`architecture-review-2026-09.md` all name items of this list by number. An item that is done keeps its number
and says so.

---

## What is done and what is not

Every section of this page, in the order it appears. A ticked box means the section's work is finished, not
merely that the section exists.

### What is established

- [x] **[The radio works](#found-the-radio-works)** -- scan, connect, resolve, log in on the vendor PIN, read
      every characteristic the app reads, receive face turns. Measured on the cube, 2026-09-06 and again
      through the app itself on 2026-09-13.
- [x] **[The core compiles, and the whole of it does](#found-the-core-compiles-and-the-whole-of-it-does)** --
      `FacetCore` entire, no `-Xcc`, no subset. The four blocking imports are all closed.
- [x] **[The module split cost 589 access-level edits](#found-the-module-split-cost-589-access-level-edits)**
      -- one-off, done 2026-09-07, and the method is written down for the next change of this kind.
- [x] **[A second platform cost the core nothing](#found-a-second-platform-cost-the-core-nothing)** -- not one
      core module needed a line changed to run on Linux. That is the ports model's central claim, audited.
- [x] **[`@MainActor` is not the main thread here](#found-on-linux-mainactor-is-not-the-main-thread)** -- the
      platform fact, the two ways it destroyed a run, and the two gates that now fail on the Mac the moment
      either is reintroduced.
- [x] **[A symlinked directory reads as empty](#found-a-symlinked-directory-reads-as-empty-and-the-bootstrap-called-that-success)**
      -- a corelibs difference that made `DatabaseBootstrap` report an empty database as created. Both halves
      fixed 2026-09-06.
- [x] **[A GTK3 app is drivable, and the tray is a D-Bus object](#found-a-gtk3-app-is-drivable-and-the-tray-is-a-d-bus-object)**
      -- press, type, toggle and read back with no mouse, while the window is covered. The tray is easier here
      than on the Mac.
- [x] **[The core runs from a real binary](#found-the-core-runs-from-a-real-binary-and-the-resource-bundle-would-ship-broken)**
      -- XDG data directory, DDL through the bundle, instance lock, keyring. One packaging fault found, which
      `docs/distribution.md` has to satisfy.
- [x] **[The whole device half works on the cube](#found-the-whole-device-half-works-on-the-cube)** -- pair,
      rotate the PIN, reconnect, ingest history, file a `time_entry`. Three faults found that 1,885 hermetic
      tests could not see.
- [x] **[CI runs the suite on both platforms](#ci-runs-the-suite-on-both-platforms)** -- four test jobs, two
      per platform, and `all-tests-pass` requires all four.
- [x] **[The toolkit is decided](#decided-one-process-swift-calling-gtk3-through-a-modulemap)** -- one process,
      Swift calling GTK3 and the Ayatana indicator through a modulemap. No bindings to keep in step.

### What is left

**Each item says which system's code the work is in.** **macOS** is `Sources/FacetMac`, **Linux** is
`Sources/FacetLinux`, and **Core** is `FacetCore`, `Tests/` or the repository itself, which either machine can
do and both have to keep green. Numbers are addresses and are never reused, so the list is not in priority
order; [what each machine owes](#what-each-machine-owes) is the same list split by system.

- [x] **[1](#1---core---settle-the-mainactor-question)** - Core - Settle the `@MainActor` question. **Done
      2026-09-06.**
- [x] **[2](#2---macos---separate-the-platform-half-from-the-portable-half)** - macOS - Separate the platform
      half from the portable half. **Done 2026-09-07**; `FacetCore` is 111 files and still growing as the
      remodel moves decisions in.
- [x] **[3](#3---core---platform-aware-data-directory)** - Core - Platform-aware data directory. **Done
      2026-09-07.**
- [x] **[4](#4---core---the-three-foundation-gaps)** - Core - The three Foundation gaps. **Done 2026-09-07**;
      one of the three is guarded rather than solved, and says so.
- [x] **[5](#5---core---make-databasebootstrap-refuse-an-empty-ddl-listing)** - Core - Make `DatabaseBootstrap`
      refuse an empty DDL listing. **Done 2026-09-06.**
- [x] **[6](#6---core---migrate-the-test-suite-to-swift-testing)** - Core - Migrate the test suite to
      swift-testing. **Done 2026-09-09**, and a gate keeps it done.
- [x] **[7](#7---linux---security-to-the-login-keyring)** - Linux - `Security` to the login keyring. **Done
      2026-09-07**, through `secret-tool` rather than libsecret.
- [x] **[8](#8---core---cryptokit-to-a-written-sha-256)** - Core - `CryptoKit` to a written SHA-256. **Done
      2026-09-07.**
- [x] **[9](#9---core---network-to-a-plain-socket-listener)** - Core - `Network` to a plain socket listener.
      **Done 2026-09-07**; both halves live in one core file, which item 16 is about splitting.
- [x] **[10](#10---linux---the-bluez-adapter)** - Linux - The BlueZ adapter, the Linux slot in the radio square.
      **Done, and proven on the cube 2026-09-13.**
- [x] **[11](#11---linux---the-ui-filling-the-gtk-slots)** - Linux - The UI: filling the GTK slots. **The menu
      bar, the dialogues and all five Settings tabs, built and confirmed on screen 2026-09-16**, four of them
      against a real cube, **the factory reset among them**. Two controls are deliberately absent and each says
      which item has to land first: Google sign-in ([16](#16---macos--linux---split-googleloopbacklistener) then
      [15](#15---linux---google-sign-in-on-linux)) and the cube rename
      ([17](#17---macos---renamedevice-onto-devicesettingwrite)).
- [ ] **[12](#12---linux---the-scripted-suite-on-linux)** - Linux - The scripted suite on Linux.
      **Deliberately low priority (owner, 2026-09-16)**: neither the suite nor its Linux half is edited or run
      until confirming a feature genuinely needs it.
- [ ] **[13](#13---core---repo-restructure-and-the-claudemd-split)** - Core - Repo restructure and the
      `CLAUDE.md` split. **Not started.**
- [x] **[14](#14---core---readme)** - Core - README. **Done 2026-09-16**; it describes two platforms and the
      three targets.
- [ ] **[15](#15---linux---google-sign-in-on-linux)** - Linux - Google sign-in on Linux. **Not started**;
      nothing in the Linux composition root names Google at all.
- [ ] **[16](#16---macos--linux---split-googleloopbacklistener)** - macOS + Linux - Split
      `GoogleLoopbackListener`. **The one item with real work on both machines**, and what empties the
      platform-blind allowlist.
- [ ] **[17](#17---macos---renamedevice-onto-devicesettingwrite)** - macOS - `renameDevice` onto
      `DeviceSettingWrite`. The last unticked row of the ports plan's window arm.
- [x] **[18](#18---macos---confirm-the-read-back-window-on-corebluetooth)** - macOS - Confirm the read-back
      window on CoreBluetooth. **Answered 2026-09-16 from the trace: it never delivered into it**, 133
      opportunities and zero occurrences, so the two faults were BlueZ's alone.
- [x] **[19](#19---macos---the-history-timer-never-restarts-when-a-cube-arrives-late)** - macOS - The history
      timer never restarts when a cube arrives late. **Fixed 2026-09-16**, behind a named list a new gate reads.
- [x] **[20](#20---macos---remove-the-twelve-compiler-artefacts-at-the-repository-root)** - macOS - Remove the
      twelve compiler artefacts at the repository root. **Done 2026-09-16**; a clean build does not reproduce
      them, which was the item's open question.
- [x] **[21](#21---macos---reconcile-the-claudemd-scripted-suite-wording)** - macOS - Reconcile the `CLAUDE.md`
      scripted-suite wording with the 2026-09-16 instruction. **Done 2026-09-16.**
- [x] **[22](#22---linux---secrettoolstores-doc-comment-describes-an-arrangement-that-is-gone)** - Linux -
      `SecretToolStore`'s doc comment describes an arrangement that is gone. **Done 2026-09-16**: the comment by
      the Mac, and the redundant `#if` by the Linux box, which can compile it.
- [x] **[23](#23---core---the-ci-workflows-test-counts-are-stale)** - Core - The CI workflow's test counts are
      stale by a factor of ten. **Done 2026-09-16**, comments only.
- [ ] **[24](#24---macos---libshs-quit_app-bypasses-platform_quit_app)** - macOS - `lib.sh`'s `quit_app`
      bypasses `platform_quit_app`. **Mac work that blocks item 12**: no Linux check can run while every check
      script quits through the macOS-only copy. Deferred with item 12 rather than fixed blind.
- [ ] **[25](#25---core---the-auto-pause-write-sets-the-cube-to-the-wrong-value-for-three-round-trips)** - Core -
      The auto-pause write sets the cube to the wrong value for three round trips. **Measured on both platforms**;
      the fix wants `DeviceSettingRows` adopted on the Mac first, so there is one place to hold the flag.

### What is still open

- [ ] **[Open questions](#open-questions)** -- seven, each with what would answer it. Three need the cube in
      range of both machines at once and cannot be answered from either alone.

---

## Where it stands

| Question | Answer | When |
|---|---|---|
| Can Linux talk to the cube? | **Yes**, every stage, on real hardware | 2026-09-06 |
| Does the core compile on Linux? | **Yes, `FacetCore` entire.** No `-Xcc`, no scratch package, no subset | 2026-09-07 |
| Does the app run on Linux? | **Yes.** It boots, takes the instance lock, applies the DDL, pairs a cube, times it, files `time_entry` rows and quits from its own tray menu | 2026-09-13 |
| Does the logic behave? | **Yes.** `swift test` is green on both platforms and has been since 2026-09-09 | 2026-09-16, Mac |
| How much of the suite runs here? | **1,417 of 1,962 tests**, derived by counting rather than run today -- 680 under XCTest and 737 under swift-testing. The Linux box's own last report was 737, which is that swift-testing figure exactly | derived 2026-09-16; last Linux run 2026-09-13 |
| What is still excluded? | **32 files, 545 tests, every one of them XCTest**, all needing AppKit, CoreBluetooth or a `FacetMac` type. `EveryLinuxExclusionEarnsItsPlaceTests` fails if one stops needing them | 2026-09-16, Mac |
| Is there a UI? | **A tray item and a Settings window, and both work.** GTK3 and `AyatanaAppIndicator3` through a modulemap, one process, one language. **All five tabs are built**; what is missing is Google sign-in, the cube rename and a factory reset, each waiting on a named item | 2026-09-16 |
| Is the device half composed? | **Yes, and every part of it answered on a real cube**: scan, reach, login, PIN rotation, history, face turns, the quit sequence | 2026-09-13 |
| Does CI check any of this? | **Yes.** Two Linux jobs mirroring the macOS pair, `swift:6.2-noble` on `ubuntu-latest`, a private `dbus-daemon` for the bus tests, 2 skipped for want of a BlueZ adapter | 2026-09-09 |
| Can a scripted check drive a Linux window? | **Yes, and it was, to confirm the Categories tab**: AT-SPI presses, types, sets and reads back, and screenshots go by window id. `Tests/Methods.md` Method 20. **There is no Xvfb on the box**, so it costs the owner's screen | 2026-09-16 |
| Can a scripted check drive the Linux app? | **The mechanism is proven and no check has run, and that is a priority rather than a blocker.** `scripts/tray-menu.py` drives the tray over D-Bus and `platform.sh` has no unfilled Linux branch left. The suite is low priority by the owner's instruction, 2026-09-16 | 2026-09-13 |
| What does a second platform cost the core? | **Nothing, measured.** Not one `FacetCore` module needed a line changed. There is no `#if os(Linux)` anywhere in `Sources/` | 2026-09-11, re-checked 2026-09-16 |

**The strategy this settles: port the core, do not reimplement it.** The Swift is portable, so the decision
logic and the hermetic suite come across rather than being rewritten against the documents. That was the fork
the spike existed to resolve, and every measurement since has gone the same way.

## Written against the ports model

The core states each platform capability as a port and something outside hands over the thing that does it, so
the Linux job is not "reimplement the half that is AppKit" but "fill the empty slot in each square".
[architecture-ports-plan.md](architecture-ports-plan.md) tracks that remodel arm by arm and is the newer
document wherever the two disagree. `CLAUDE.md` carries the rule and
[architecture-model.svg](architecture-model.svg) is the picture.

**What this file is for, and the other is not:** this one is the record of what a machine did. Everything in
it that is marked measured was really measured, on the date and machine it names, and none of it expires when
code moves, because the findings are facts about machines rather than about the tree.

## The machines it was measured on

**The Mac**: macOS 26.6.2 (Darwin 25.6.0) on arm64, **Swift 6.3.3**. `Package.swift` declares
`swift-tools-version: 6.0`, which is the *language and manifest* level rather than the compiler, so nothing
here says the package builds under a 6.0 toolchain and no machine has one.

**The Linux box**: a `MacBookPro14,2` running Linux Mint 22.3 "Zena" (Ubuntu 24.04 noble base), MATE 1.26.1 on
**X11**, kernel 7.0.0-31-generic, Intel i7-7567U, `x86_64`. Adapter `hci0` at 88:E9:FE:5F:1B:52. Cube
`TimeFlip v2.0` at E8:DB:D8:CF:F9:0F, `DI_LABS` / `2.0` / `TFv4.1` / `FW_v3.64`.

**The two machines differ by instruction set as well as by operating system**, so no built artefact is
interchangeable and a timing figure from one is not a fact about the other.

Already present on the Linux box, needing no installation: BlueZ 5.72, `python3-dbus`, `python3-gi`,
`libayatana-appindicator3`, `mate-indicator-applet`. **A tray icon is native on MATE**, which is the desktop
this is built for; GNOME dropped tray support and needs an extension. **X11 matters** because synthetic input
goes through XTEST, which Wayland has no equivalent for that a normal process may call.

Swift 6.2 is unpacked at `~/.local/swift/swift-6.2-RELEASE-ubuntu24.04` and is **not on `PATH` by default**:

```sh
export PATH="$HOME/.local/swift/swift-6.2-RELEASE-ubuntu24.04/usr/bin:$PATH"
```

Full per-machine facts are in [systems-info.md](systems-info.md), which is where they belong.

### There is one cube, and whichever machine paired last owns its PIN

**It is on the Mac as of 2026-09-16**, and moving it between machines is not something to plan around.

**A pairing rotates the PIN off the vendor default and keeps it in that machine's keyring**, which is
`DevicePINRules.rotates(from:)` working as designed. So the other machine cannot log in afterwards. **The fix
is to pull the batteries and put them back**, which returns the cube to `000000` (measured 2026-08-11, in
[timeflip2-firmware-observations.md](timeflip2-firmware-observations.md)); both machines' reconnect candidates
append the vendor default, so the next pairing simply works.

**That is a minute of work, so it is not a blocker and should not be written up as one.** If a machine cannot
reach the cube, pull the batteries and pair again. Nothing in the port waits on it and no run needs to be
planned around it.

**What a pairing does leave behind is worth knowing**, because it is not only the PIN: the face colours are
whichever machine's twelve, along with its LED brightness, blink period and auto-pause delay. The Linux pairing
of 2026-09-13 left brightness at 50%, blink at 15s and **auto-pause at zero where the Mac had five minutes**,
and carried only two categorised faces (`Break` on 8, `Meeting` on 2). A pairing from the other side re-sends
its own, so this corrects itself rather than needing tidying up.

**Only one host may hold the link at a time**, which is the constraint that does matter: a device run on either
machine means quitting Facet on the other first.

---

## Found: the radio works

**Measured 2026-09-06 against the real cube**, and again through the app itself on 2026-09-13. Full detail in
[linux-bluez-port-notes.md](linux-bluez-port-notes.md); firmware behaviour in
[timeflip2-firmware-observations.md](timeflip2-firmware-observations.md) finding 12.

Scan, connect, resolve, log in on the vendor PIN, read every characteristic the app reads, and receive face
turns live. `scripts/linux-ble-probe.py` is the run and remains the way to ask the cube something with no app
in the way.

Two things easier than on macOS: **no pairing agent** (`Paired: 0`, `Bonded: 0` -- the PIN is the whole of the
authentication) and **no `sudo`**.

One trap that cost the first two runs: **do not filter discovery on the service UUID.** The cube advertises
none. That is finding 12, and it is why `BluetoothRadio` passes `withServices: nil`.

**Finding 4 holds through a second stack.** `0x02` on the command result means a correct PIN, not the `0x01`
the vendor spec promises. Finding 4 measured that over CoreBluetooth in August; this measured it over BlueZ
and libdbus. Two hosts, two Bluetooth stacks, the same inverted byte -- which matters because that byte
decides whether the right cube is let in.

## Found: the core compiles, and the whole of it does

**`swift build --target FacetCore` completes on Linux** (2026-09-07): the target as it stands in the tree, no
`-Xcc`, no scratch package, no selected subset, with its resource bundle carrying every `.sql` file.

The spike's number was **53 files** -- the *closed set*, being those referencing nothing outside themselves
plus Foundation, computed rather than chosen so the result was not flattered by a convenient selection. What
stood between that and the whole target was four unguarded imports, each a hard stop hiding the next:

| Import | Files then | What it is now |
|---|---|---|
| `SQLite3` | 4 | A `systemLibrary` target named `SQLite3`, in the graph on Linux only. **No source file changed** |
| `Security` | 2 | The login keyring through `secret-tool`. Item 7 |
| `CoreGraphics` | 2 | One `package typealias CGFloat = Double`. It **has to be `package`**: a plain one is `internal`, which a `package` member may not use, so the naive fix trades four missing-module errors for 22 access errors |
| `CryptoKit` | 1 | `PortableSHA256`, compiled everywhere and called on Linux. Item 8 |

Behind all four was **76 errors in three files and nothing in the other 83**: 75 diagnostics over 19 distinct
`Security` symbols in the two Keychain stores, and one `SHA256` call in `GoogleOAuthRules`.

The date and timezone handling, which was the risk expected to bite hardest, produced **not one error**. The
`Locale(identifier: "en_US_POSIX")` discipline throughout the codebase is why.

**`SQLite3` needs the modulemap even with `libsqlite3-dev` installed** -- measured 2026-09-07, with the package
present and `import SQLite3` failing exactly as before, because the Swift toolchain ships no `SQLite3` module
for this platform. The package is what lets the modulemap name the real `/usr/include/sqlite3.h` and lets a
link find `libsqlite3.so`; it is not a substitute for it. Stock Mint ships only `libsqlite3.so.0`, and the
unversioned symlink is what `libsqlite3-dev` provides.

### The three genuine Foundation gaps

| Gap | Where | What happened |
|---|---|---|
| `URLRequest`, `URLSession`, `URLResponse` moved to `FoundationNetworking` | the three Google clients | `#if canImport(FoundationNetworking)`. Mechanical; cleared 251 errors |
| `abbreviatingWithTildeInPath` does not exist in corelibs | `DebugTraceRules` | Written out by hand, with tests for the two edges the API gave for free: the home directory abbreviates to `~`, and a sibling whose path merely *starts* with the home path is not inside it |
| `setvbuf(stdout, ...)` | `DebugLog` | **Guarded to Darwin rather than solved.** glibc declares `stdout` as a mutable global and Swift 6 refuses every reference to it, including one captured into a `let`. A Linux terminal loses the immediacy of the printed copy; `debug_log` still gets every row, which is the half the scripted checks read |

### What the core still reaches for, and it is not an `#if`

**The platform-blind allowlist is down to one file**: `GoogleLoopbackListener`, which is two implementations in
one file and cannot come off until it is split in two. `PlatformBlindCoreTests` fails on anything else.

**That gate sees only violations that announce themselves.** Re-measured 2026-09-16: **10 files in `FacetCore`
reach a platform capability with no conditional at all**, on `applicationSupportDirectory`, `Bundle.main`,
`sqlite3_*`, `FileManager.default` or `flock`. Nine of the ten are storage or the files around it, which is not
debt: storage was ruled off the diagram as not being a platform capability, and `import SQLite3` is the same
line on both platforms. **`InstanceLock` is the tenth and the real one**, being `flock`, `errno` and `strerror`
with no conditional anywhere. It is a port for Windows, and Windows is not in scope.

## Found: the module split cost 589 access-level edits

**Measured on the Mac, 2026-09-07**, by making the split rather than by counting declarations.

| | Estimated, from Linux | Measured, on the Mac |
|---|---|---|
| Types that had to be widened | 103 | **152** |
| Members that had to be widened | ~511 (upper bound) | **437** |
| **Total `package` declarations** | ~614 | **589** |
| `public` keywords anywhere | 0 | **0**, still |

**The type count was low by half, and the reason is worth knowing before estimating this kind of change
again.** The script counted the types `FacetMac` names directly. What the compiler asks for is those plus
everything that comes with them: a type used in a `package` signature, a nested type behind a `package` enum
case, and a parent that has to widen so its own nested type is reachable at all. The member count came in
**under** its upper bound, which is what an upper bound is for.

**It cannot be read off one build.** The first build of `FacetMac` against `FacetCore` reported 4,801 error
lines naming 94 types; widening those exposed the next layer, and so on for a dozen rounds. Until a type is
visible the compiler cannot say which of its members are wanted.

**What made the loop tractable: Swift emits `note: 'x' declared here` beside each access error, carrying the
declaration's own file and line.** That is the whole input a widening pass needs -- no name matching, no
inferring a receiver's type, nothing widened that the build did not point at. The first attempt matched on
member names instead and was ambiguous for 15 of 70; the note-driven pass had no ambiguity at all.

**Two guesses did creep in, and the compiler caught both**, which is the argument for the discipline rather
than against it: `package` on three local `let`s inside function bodies, where it is a compile error rather
than merely wrong, and a generated memberwise initialiser that had swept up locals from the function bodies of
the struct it belonged to.

**Seven memberwise initialisers had to be written by hand**, Swift not widening a synthesised one with its
type. That is the only part of the stage that is not mechanical.

**The grep to drive the loop with** is `cannot find (type )?'X' in scope`, and the useful form is the distinct
sorted list of names inside the quotes. An `internal` declaration in another module is not visible at all
rather than visible-and-refused, so the compiler never says "is internal and cannot be referenced"; the stage 3
recipe in [facetcore-split.md](facetcore-split.md) still looks for that string and is wrong to.

**Two files were carrying an `import AppKit` they had stopped needing**, which the Linux side could not see
because it computed the move list from the import lines themselves. **An import line is evidence of what a file
needed once**, and the compiler is the only authority on what it needs now.

## Found: a second platform cost the core nothing

**Audited 2026-09-11, after filling five Linux slots in a day, and re-checked 2026-09-16.** The claim the ports
model makes is that a second platform is adapters and nothing else. **It held, and the number is zero**: not
one core module needed a line changed to run on Linux. `DeviceLogin`, `DeviceReconnector`,
`CubeCommandChannel`, `HistoryIngestor`, `HistoryTimer`, `CubeLock`, `FaceColourSync`, `DeviceSettingsSync`,
`LowBatteryWatch`, `DailyLimitWatch`, `ForcedPauseWatch` and `QuitSequence` were all constructed in a second
composition root and ran. **There is no `#if os(Linux)` anywhere in `Sources/`.**

Where the targets stand today (2026-09-16):

| Target | Files | Lines | What it is |
|---|---|---|---|
| `FacetCore` | 111 | 17,763 | Everything both platforms decide |
| `FacetMac` | 37 | 13,591 | AppKit and CoreBluetooth. 3,206 of those lines are `SettingsWindowController` |
| `FacetLinux` | 12 | 3,384 | GTK, BlueZ over libdbus, the keyring, and the composition root |

**The core growing is the port shrinking.** Those numbers are not a target to hold: the remodel goes on moving
decisions in, and `FacetMac` falling towards nothing but drawing and CoreBluetooth is the intended end of it.

**Three things had to move, and each is the same shape**: a decision written down inside a platform target that
the second platform needed too.

- **The BLE trace.** Ten `debug_log` wordings keyed on `CBUUID` in `FacetMac`. They are read back by
  `Tests/Scripted` with `LIKE` and `GLOB`, so they are interface, and a second radio would have written a
  second copy that diverged one row at a time.
- **The seeded device settings.** Five numbers inside an AppKit view. They are `database/011_setting.sql`'s own
  seeds and any composition root reading a fresh database needs them.
- **The Settings line in the dropdown.** `StatusItemMenu` always drew one, and this platform has no window to
  open. `openSettings` is optional now and `nil` means the line is not offered.

**One thing went the other way and is worth naming as a limit.** The Linux menu carries lines the Mac has no
equivalent for -- a list of today's totals standing in for a Report tab, a pairing control standing in for a
Device tab. Those are that platform's composition root's, marked as such, and they are what item 22 of
[handover-linux.md](handover-linux.md) predicts: a second platform finds decisions the first never had to make.

**And one asymmetry turned out to be the argument for a port rather than a cost of one.** `Dialogue.wayOut`
carries a *position*, because AppKit relocates a button titled Cancel and takes Return off the way out. GTK
relocates nothing, so the Linux adapter honours the field in one line. A port whose shape was chosen by one
platform's difficulty cost the other nothing.

**One core type changed shape because of this port, and it was an improvement rather than a concession.**
`DeviceHandle` is an opaque token the adapter mints and the core never reads. It used to be a `UUID`, which was
CoreBluetooth's shape reaching into the circle: BlueZ has no such identifier, only the device's real address,
so the Linux side had to pack six address bytes into the last six of a UUID behind a marker and check the
marker on the way back out. Eighty-four lines and six tests existed to make an address look like something it
is not. They are gone, and a Linux adapter stores the address as the address.

## Found: on Linux, `@MainActor` is not the main thread

Two separate faults, both fatal, both invisible to the author, and both now guarded.

### An isolated `XCTestCase` aborts the entire run

Linux discovers tests through a generated list rather than the Objective-C reflection Apple platforms use, and
it cannot cast an isolated test method:

```
Could not cast '(CubeLockTests) -> @MainActor () -> ()' to '(CubeLockTests) -> () -> ()'
```

**One such class aborts the whole test executable** -- not a skip, a crash that takes every other test with it.
Measured twice over: on 2026-09-10 three such files had reappeared and **671 XCTest tests reported nothing at
all**, the only output being that message naming one class.

**The shape of the fault is why it does not stay fixed on its own.** The author cannot see it, the machine that
can see it is not the one being typed at, and the failure names one file while destroying the run of every
other. Nothing in the source says the attribute is dangerous.

**`AnIsolatedXCTestCaseAbortsTheLinuxRunTests` is the guard**, and it runs on both platforms, which is the
whole point: it fails on the Mac at the moment the attribute is typed. It reads the exclusion list **out of
`Package.swift` rather than keeping a copy**, so a file coming off that list is checked from that moment
without anybody remembering to say so.

**Two ways out.** If the subject really is `@MainActor`, the file becomes a `@Suite @MainActor` swift-testing
suite. If it is not, the attribute is simply deleted -- which is the common case now, isolation being left
behind by a subject that moved into the core and stopped touching AppKit.

### And the actor is not the thread

**Measured 2026-09-09.** Inside a `@Suite @MainActor` swift-testing suite on this platform:

| Probe | Answer |
|---|---|
| `Thread.isMainThread` | **false** |
| `RunLoop.current === RunLoop.main` | **false** |
| a `Timer` on `RunLoop.main` in `.common`, spinning `.default` | **never fires** |
| the same on `RunLoop.main` in `.default`, spinning `.default` | **never fires** |
| the same on `RunLoop.current` in `.common`, spinning `RunLoop.current` | **fires at once** |

The isolation is honoured -- the body really is serialised on the main actor -- but the actor is not the thread
whose run loop `RunLoop.main` hands back. Under XCTest the two coincided.

**It was confirmed the expensive way.** `WriteDebounce` and `LowBatteryWatch` both scheduled on `RunLoop.main`,
so migrating their suites traded one load-time abort for seventeen silent failures: `WriteDebounceTests`
reported `writes -> 0` and `written -> []` on four tests before the probe explained why.

**Three ways out, and the third is the one taken.** swift-testing could run `@MainActor` on the main thread on
Linux, which is not in this repository's gift. Or the `RunLoop` becomes a parameter -- a production change made
for a test's benefit, where `RunLoop.main` states what the app actually wants and `RunLoop.current` would pass
by coincidence. **Or the seam goes at "the timeout happened" rather than at "here is a RunLoop"**, which is
smaller than threading a scheduler through two initialisers.

**That is now a port rather than a workaround.** `Scheduler` is the clock arm, with `RunLoopScheduler` on the
Mac, `GLibScheduler` on Linux and `HandDrivenScheduler` for tests, and it is the first green square on the
figure. `PlatformBlindCoreTests.theCoreUsesItsPorts` bans `RunLoop` and `Timer.scheduledTimer` in the core
outright -- the second because it adds to a run loop **without naming one**, which would have walked straight
past a check that only looked for the first.

**A smaller Linux-only difference found beside it.** swift-corelibs-foundation does not mark
`RunLoop.run(mode:before:)` `@discardableResult`, so the bare call warns here where it does not on Darwin.

### What the swift-testing migration cost

Mostly mechanical, and the 2026-09-09 pass converted 264 assertions across the last four files with a string-
and comment-aware converter rather than a plain regex.

| XCTest | swift-testing |
|---|---|
| `final class X: XCTestCase` | `@Suite final class X` |
| `func testFoo()` | `@Test func testFoo()` |
| `XCTAssertEqual(a, b)` | `#expect(a == b)` |
| `XCTAssertTrue(a)` / `XCTAssertFalse(a)` | `#expect(a)` / `#expect(!(a))` |
| `try XCTUnwrap(a)` | `try #require(a)` |
| `setUpWithError()` | `init() throws` |
| `tearDown()` | `deinit` -- **and this one does not map** |

**The hazard, and it crashes rather than fails.** `tearDown` in this suite wrapped its work in
`MainActor.assumeIsolated`. A `deinit` carries no actor context *even on a `@MainActor` class*, so the
assumption traps: SIGILL, no message, after every test has already reported starting. **27 of 30 `tearDown`
bodies were in that position** (measured 2026-09-07). Cleanup in a `deinit` has to be callable without
isolation, and each one needs looking at individually.

Seven more differences, each of which cost a compiler round or a run to find:

- **A regex walks into two traps.** An operand whose top level holds an operator binding looser than `==` has
  to be parenthesised, or `XCTAssertEqual(a ?? b, c)` becomes `#expect(a ?? b == c)`, which compiles and asks
  `a ?? (b == c)`. And a `String` *variable* passed as a message is not a `Comment`, where a string *literal*
  becomes one on its own. Neither fails loudly.
- **`Testing` does not re-export Foundation** the way `XCTest` did. Seven files needed `import Foundation`.
- **`try` is fine at the start of an `#expect` and illegal to the right of an operator.**
  `#expect(try #require(a).isActive)` compiles; `#expect(a < try #require(b))` does not.
- **`accuracy:` has no equivalent**, `#expect` taking one expression rather than a pair. Six colour-channel
  comparisons went through a named `isApproximately` so the tolerance stays visible.
- **XCTest assertions absorb a thrown error and `#expect` does not.** Hoisting an unwrap out of a comparison
  makes the test `throws`, and the compiler is the one that says so.
- **`.immutable` is a BSD file flag corelibs does not implement**, and a `try?` around it swallowed the
  refusal, so a test asserting that an unwritable file is not reported as settled *failed on Linux against an
  app behaving correctly*. The portable equivalent is taking write permission off the **file** (`0o400`) --
  not the directory, because the write it has to refuse is in place and needs no directory permission.
- **Cleanup is no longer deterministic.** `deinit` runs when ARC says so, and at process exit some instances
  are never released at all, so a full run leaves a dozen or so `facet-db-*` directories in `/tmp` where XCTest
  left none. Harmless, but the sort of thing somebody would go hunting for.

**Timing was a wall and then was not.** The seeded `timezone` table added 599 statements per bootstrap, and
sqlite gives every statement outside a transaction one of its own with an fsync attached: 6.2s per test, at
which point the suite in parallel never finished a single one in ten minutes. **Fixed by applying each DDL file
in one transaction** -- a 64-fold difference on the seed file alone, 3.87s to 0.06s, and a bootstrap from 6.2s
to 0.9s. The number that matters is the per-statement fsync rather than the DDL's size.

## Found: a symlinked directory reads as empty, and the bootstrap called that success

**Two faults that compound, and the repository was already arranged to trigger them.** Measured 2026-09-06,
same directory, same process:

| | `contentsOfDirectory(at: URL)` | `contentsOfDirectory(atPath:)` | `at:` after `resolvingSymlinksInPath()` |
|---|---|---|---|
| **through a symlink** | **0** | 15 | 15 |
| the real path | 15 | 15 | 15 |

Darwin follows the link. Corelibs returns an empty array.

**And the second fault is what turns a wrong answer into a silent one.** `DatabaseBootstrap.ensureDatabase`
filtered the listing and applied what survived; **an empty listing applied nothing and returned successfully**
-- `createdDatabase: true`, `filesApplied: []`, no error thrown. The result is a database with no tables,
reported as a database that was created. That is how this was found: every setting read came back `nil` and
nothing anywhere said why.

**Both halves are fixed** (2026-09-06). `ensureDatabase` resolves symlinks before it enumerates, and throws
`Failure.ddlDirectoryEmpty` rather than returning success on an empty listing. The second is a fix on macOS as
much as Linux -- a DDL directory yielding no files is never a correct outcome, and `CLAUDE.md` already carried
the rule it broke. Verified against the exact failure case: with the DDL reachable only through a symlink, the
21 `CubeLockTests` pass where the same arrangement previously produced a database with no tables.

**The link was also flipped**, in the same change. `database/` at the repository root is now the real
directory and `Sources/FacetCore/Resources/Database` is the symlink, because the schema is shared and neither
platform owns it; the only reason it ever lived inside a platform target is that SwiftPM requires a target's
resources to sit inside the target. **No runtime code path traverses a symlink at all** now. Only SwiftPM's
resource bundling does, at build time, and it follows the link on both platforms -- verified on the Mac
2026-09-06 and again after the split moved it, with every `.sql` file present in `Facet_FacetCore.bundle`
(17 of them today, alongside `google-client.json`).

**One detail that looks like a fault and is not: `.process` flattens**, so the files land at the root of the
bundle and there is no `Database/` directory in it. `DatabaseBootstrap.bundledDDLDirectory` asks for
`001_event_type.sql` by name and strips the filename rather than asking for a directory, and its comment says
so.

**Narrowed 2026-09-07**: this is specific to a symlinked *directory*. A symlinked **file** inside a real
directory is listed by both spellings and read straight through by `String(contentsOf:)`. So a report to the
corelibs tracker has a smaller and sharper case than the original finding suggested.

**A symlinked file inside a resources directory is a different trap and is measured.** SwiftPM copies it into
the bundle *as a symlink*, whose relative target no longer resolves from where it lands -- which is why
`FacetLinux`'s tray icon is a copy rather than a link, and why the DDL can be a link and a single file cannot.

## Found: a GTK3 app is drivable, and the tray is a D-Bus object

**Measured on the Linux box, 2026-09-08**, against a 90-line Python/GTK3 stand-in shaped like the parts a
scripted check has to reach. Every claim was confirmed twice over: the action returned successfully **and** the
app recorded that it happened.

| | |
|---|---|
| **AT-SPI sees a GTK3 app** | Yes -- 26 applications on the accessibility bus, the probe among them |
| **`toolkit-accessibility` does not gate it** | The gsetting reads `false` and the app was visible anyway. GTK3 loads the atk-bridge on its own. **Worth knowing because the obvious first move is to turn it on**, and doing so would have credited the wrong thing |
| **Accessible name is the `AXIdentifier` equivalent** | `widget.get_accessible().set_name(...)` comes back as the node's `name`, and a locator is one tree walk comparing it |
| **Pressing** | `queryAction().doAction(0)` on a `push button`. **No mouse event, no coordinates** |
| **Typing** | `queryEditableText().setTextContents(...)`; the app's `changed` handler fired |
| **Toggling** | `doAction(0)` on a `check box`, read back as `STATE_CHECKED` |
| **Reading for assertions** | Label text via `queryText().getText(0, -1)` -- `name` stays the identifier and the text is the value, the same split as `AXIdentifier` against `AXValue` |
| **While unfocused and covered** | Yes. Another window was raised over it and made active, and the press still landed. **This is the difference that matters most for the suite** |

### The tray is not in the accessibility tree, and that is better here

**The indicator is absent from AT-SPI entirely** -- the application node has exactly one child, the frame. That
is the same shape as the macOS status item, which `Tests/Methods.md` records as not being in `AXMenuBar`. What
differs is what replaces it: on the Mac, real mouse events through `scripts/status-item-click.py`; here, a
D-Bus object.

```sh
# it registers itself, and the watcher lists it
org.kde.StatusNotifierWatcher -> RegisteredStatusNotifierItems

# the menu is a property, and com.canonical.dbusmenu reads and drives it
GetLayout(0, -1, [label])   # every line, with whether it is enabled
Event(id, "clicked", "", 0) # choose one
```

`scripts/tray-menu.py` is that, committed, and `Tests/Methods.md` Methods 18 and 19 are how to use it. It works
while the session is doing something else, which on macOS costs a real `CGEvent` and a frontmost app.

**Three corrections to the first spike, all measured 2026-09-13 and all load-bearing:**

- **No identifier crosses.** `StatusItemMenu.Item.identifier` reaches `AXIdentifier` on the Mac and reaches
  **nothing** here. Neither `gtk_widget_set_name` nor the accessible description is carried; `GetLayout`
  answers the label plus `enabled`. **So a Linux check addresses a tray item by its label**, and that is a
  difference to design the checks around rather than discover in one.
- **The numeric ids are libdbusmenu's own** and are reassigned on every rebuild, so an id read in one step is
  meaningless in the next. The first spike recorded ids 2, 3 and 4 as though they were stable.
- **The `Event` signature is `isvu`, not `issu`.** The data argument is a variant, so python-dbus needs
  `dbus.String("", variant_level=1)` and an explicit signature, or the call is refused.

**The tray label reads back too**: `XAyatanaLabel` on `org.kde.StatusNotifierItem` answers what
`StatusItemReadout` produced, so a check can assert the menu-bar clock directly. Colour cannot be read -- an
`AppIndicator` label is plain text -- which is why the readout writes the colour decisions to `debug_log`, the
only way a check sees them on **either** platform.

### What this does not say

- **Nothing was run headless.** `xvfb` is not installed and this box has no passwordless `sudo`, so whether the
  scripted suite could run without a screen is open.
- **The screen was not locked.** Whether a locked session still answers is untested.

## Found: the core runs from a real binary, and the resource bundle would ship broken

**Measured on the Linux box, 2026-09-08**, with a 45-line executable linked against the built core -- the first
Linux binary this project had. Four of the five answers are good; the fifth is a fault that would have shipped.

| | |
|---|---|
| **The data directory** | `.applicationSupportDirectory` answers `/home/harry/.local/share`, so the app's path is `~/.local/share/Facet/appdata.sqlite`. **No code change**: corelibs does the XDG layout |
| **The DDL through the bundle** | `ensureDatabase(at:)` with no `ddlDirectory` succeeded. **This path had never run on Linux** -- every test passes a directory explicitly, so the bundle lookup was untested by all of them |
| **The single-instance lock** | Two real processes: the first claimed it, the second was refused `heldByAnotherInstance` |
| **The keyring** | `SecretToolStore.lookUp` for an absent secret answered `missing` rather than `unavailable`, so the two cases are told apart as designed |

**`-package-name timeflipapp` is the part worth keeping** if the probe is ever rebuilt: it is what makes
`package` declarations visible from outside the module, and it is the package identity lowercased. Without it
every `package` symbol is simply not in scope.

### And the fault: a shipped binary dies on its resources

**`Bundle.module` on Linux is generated code with a hardcoded absolute build path in it.** SwiftPM writes a
`resource_bundle_accessor.swift` that tries the path beside the executable and then the build directory of the
machine that compiled it:

```swift
guard let bundle = Bundle(path: mainPath) ?? Bundle(path: buildPath) else { Swift.fatalError(...) }
```

So **on the machine that built it, every binary works wherever it is run** -- the fallback answers. Move the
same binary to a machine without that directory and it does not degrade, it dies. Measured by hiding the build
directory for the length of one run.

**Two things make this worse than a missing file.** It is a `fatalError`, so
`DatabaseBootstrap.Failure.ddlDirectoryNotFound` -- written precisely for "the DDL is not where it should be"
-- never gets the chance to report it, and none of the careful error handling around it runs. And it is
invisible on the build machine, which is the one place anybody would test it.

**What it costs is one packaging rule**: `Facet_FacetCore.resources` goes beside the executable. Confirmed
working with the directory copied next to the binary and the build path hidden. **That is
[distribution.md](distribution.md)'s to satisfy**, and something should check it rather than trusting it.
`FacetLinux/main.swift` already writes the bootstrap failure to stderr and exits non-zero, which is as far as
the app can help.

## Found: the whole device half works on the cube

**Measured on the Linux box against the real cube, 2026-09-13.** The first end-to-end run of `FacetLinux` with
a TimeFlip2 in the room. It paired, rotated the PIN into the login keyring, reconnected on a later launch,
brought in the cube's own history and filed a `time_entry` -- and it turned up three faults on the way, each
invisible to the hermetic suite.

| | |
|---|---|
| **Scan and reach** | `BlueZCubeRadio` found the cube by name, ordered the room and connected. On a later launch the remembered handle cut the window short, which is `CubeReachSequence`'s shortcut working over BlueZ |
| **Login** | The vendor default was accepted (`commandResult: 02`, finding 4), the PIN was rotated to six fresh digits, the cube proved it by taking a second login on the new one, and `SecretToolStore` kept it |
| **Pairing rows** | `paired`, `device_uuid`, `device_name`, `device_info` and `connection` all written. `device_uuid` holds `E8:DB:D8:CF:F9:0F` verbatim, which is `DeviceHandle` being the address rather than a packed UUID |
| **The cube's own state** | Clock set and confirmed by `0x07`; the four Device Information strings; battery 100%; all eight TimeFlip characteristics subscribed |
| **Face colours and settings** | Twelve `0x11` writes, LED brightness and blink period, and the cube's `systemState` requests answered as they arrived |
| **History** | `0x01`/`0x02` frames parsed, `device_event` rows written, and a finished segment became `time_entry` 1 -- eighteen seconds filed under Break |
| **The quit sequence** | Pause, read back, lock, read back, in that order, then the link given up |
| **Driving it with no mouse** | Every control above was reached through `com.canonical.dbusmenu` on the tray item. Pair, Pause, Unlock and Quit all landed |

**The read-back discipline comes free, and that is the point of the arm.** `CLAUDE.md` requires every command
with a read-back to be sent and then read back, and the two measured traps in the `0x10` answer -- that it
carries no echoed command byte, and that a locked cube reports itself paused whatever its pause byte says --
are decided in `FacetCore`. This adapter cannot get them wrong differently from the Mac, because it does not
decide them.

### The three faults, and one of them is shared

**`AboutToShow` reaches nothing, so a tray menu cannot be rebuilt as it opens.** `MenuBar` hung its rebuild on
the `GtkMenu` `show` signal and it never fired once:

```
17:42:50  set_menu
17:42:50  signal show          <- emitted by app_indicator_set_menu itself
17:42:54  AboutToShow(0) -> False, and no signal fires on the widget
```

There is no equivalent of `NSMenuDelegate.menuNeedsUpdate` available through an `AppIndicator`: the
`DbusmenuServer` that would forward the panel's request belongs to libayatana-appindicator and is not handed
out. **What it cost before that was found**: the menu was built once at launch and never again, so a paired,
connected app went on offering *Pair a cube* with Pause and Lock insensitive over a live device. `MenuBar`
re-reads the menu on its own tick now, and rebuilds only when what it should say differs from what it is
saying.

**No identifier crosses a dbusmenu item** -- written up under the tray section above, and the reason
`scripts/tray-menu.py` addresses by label.

**BlueZ answers a read twice, and a shared-core read-back was taking the wrong one.** A `read` on a
characteristic produces the reply *and* a `PropertiesChanged` carrying the same value a few milliseconds later,
visible all over the trace as two identical `ble-rx` rows. That is a platform fact and harmless on its own.
What it found was not: `CubeCommandChannel.isAwaitingResult` reported the *intention* to read rather than the
read, so a value arriving between writing the question and issuing the read was taken as the answer. **Every
login on this box lost the cube's `0x10` state** to the duplicate of the `0x17` before it, and a quit reported
*The cube would not take auto-pause 0m* about a write the cube had narrated as `autopause OFF` and confirmed as
zero two hundred milliseconds later.

**Fixed in `FacetCore`, and the window exists on the Mac too.** Whether CoreBluetooth ever delivers into it is
not something the Linux box can answer -- it is [handover-mac.md](handover-mac.md) item 25, and it wants a
scripted run.

---

## What is left

**Mac work is in this list too, and it has to be.** Some of what the Linux port needs is a change to
`Sources/FacetMac` or to the shared harness, and a Linux-only to-do list would leave that work with nowhere to
live. Each item is tagged with the system whose code changes: **macOS**, **Linux**, **Core** (`FacetCore`,
`Tests/` or the repository, which either machine can do), or **macOS + Linux** where there is real work on both.

Numbers are addresses and are never reused, so the order below is historical rather than a priority.

### What each machine owes

**On the Mac**, seven items, and the two at the bottom are the Linux port's business rather than the Mac's own:

| # | What | Does it block Linux? |
|---|---|---|
| [17](#17---macos---renamedevice-onto-devicesettingwrite) | `renameDevice` onto `DeviceSettingWrite` | Only when a Linux Settings window wants a rename control |
| [18](#18---macos---confirm-the-read-back-window-on-corebluetooth) | Confirm the read-back window on CoreBluetooth | **No, but the port raised it** and it may be a live fault on the Mac |
| [19](#19---macos---the-history-timer-never-restarts-when-a-cube-arrives-late) | The history timer never restarts when a cube arrives late | **No.** A Mac bug the Linux side does not have |
| [20](#20---macos---remove-the-twelve-compiler-artefacts-at-the-repository-root) | Remove twelve compiler artefacts from the root | No |
| [21](#21---macos---reconcile-the-claudemd-scripted-suite-wording) | Reconcile the `CLAUDE.md` scripted-suite wording | No |
| [24](#24---macos---libshs-quit_app-bypasses-platform_quit_app) | `lib.sh`'s `quit_app` bypasses the port | **Yes -- it blocks [12](#12---linux---the-scripted-suite-on-linux) outright**, though 12 is low priority |
| [16](#16---macos--linux---split-googleloopbacklistener) | The Darwin half of the listener split | **Yes**, for [15](#15---linux---google-sign-in-on-linux) |

**On the Linux box:**

| # | What | Size |
|---|---|---|
| ~~[11](#11---linux---the-ui-filling-the-gtk-slots)~~ | ~~The Settings window~~ | **Done 2026-09-16**: all five tabs, four confirmed against a real cube |
| [15](#15---linux---google-sign-in-on-linux) | Google sign-in | Small, but wants 11 or a decision about where to put it |
| [12](#12---linux---the-scripted-suite-on-linux) | The scripted suite | Low priority by instruction; blocked by 24 anyway |
| [16](#16---macos--linux---split-googleloopbacklistener) | The socket half of the listener split | ~200 lines, moved rather than written |
| ~~[22](#22---linux---secrettoolstores-doc-comment-describes-an-arrangement-that-is-gone)~~ | ~~A stale doc comment, and the dead `#if` under it~~ | **Done 2026-09-16** |

**On either machine**: [13](#13---core---repo-restructure-and-the-claudemd-split), the repo restructure and the
`CLAUDE.md` split, which is the only item left that is nobody's in particular. [14](#14---core---readme) and
[23](#23---core---the-ci-workflows-test-counts-are-stale) are done.

**So what is left on this side is 15 and 16, and both wait on the Mac** -- the sign-in cannot reach a listener the
core still picks for itself. With 11 finished, a Linux box with no Mac to hand has nothing left it can do alone
except 13.

### 1 - Core - Settle the `@MainActor` question

**Done 2026-09-06: swift-testing.** It came first because it decides how the test target is structured, and
doing the extraction first would have meant restructuring it twice.

### 2 - macOS - Separate the platform half from the portable half

**Done 2026-09-07.** `FacetCore` exists, `FacetMac` builds on it, and the whole package builds clean. Stage 3's
589 `package` declarations are the section above. The test target is one target with
`@testable import FacetCore` beside `FacetMac`; `ActivityIconTests` is the one exception and says why in a
comment, both targets generating a `Bundle.module` that importing both makes ambiguous.

### 3 - Core - Platform-aware data directory

**Done 2026-09-07.** The seeded `debug` row named `~/Library/Application Support/Facet`, which is the wrong
folder on Linux and sat in DDL both platforms share. It seeds `directory` as an **empty string** now, and empty
means the folder the app already keeps its databases in. `DebugTraceRules.defaultDirectory` is computed from
`applicationSupportDirectory` rather than written down, so it is right on either platform.

### 4 - Core - The three Foundation gaps

**Done 2026-09-07**, all three no-ops on macOS. The table is in the compile section above. `setvbuf` is
**guarded to Darwin rather than solved** and says so at the call site.

### 5 - Core - Make `DatabaseBootstrap` refuse an empty DDL listing

**Done 2026-09-06**, along with flipping `database/` to be the real directory. The section above is the whole
of it.

### 6 - Core - Migrate the test suite to swift-testing

**Done 2026-09-09**, and `AnIsolatedXCTestCaseAbortsTheLinuxRunTests` keeps it done.

**The lesson that cost the most was about the two lists rather than the files.** `Package.swift` carries the
exclusions with the reason attached, and for a while it carried two lists: one for files that cannot run here
at all and one for files blocked only by their testing framework. **The migration emptied its own queue while
six migratable suites sat hidden on the other list**, because a file on the platform-bound list was never a
candidate. A list of exclusions has to say which of two reasons it is, or it absorbs the other. There is one
list again now, and one reason.

### 7 - Linux - `Security` to the login keyring

**Done 2026-09-07, and not via libsecret.** `SecretToolStore` is the Linux slot in the secrets square and
`KeychainSecretStore` is the Mac's; both composition roots hand one over and the core chooses neither.

**libsecret's simple API turned out to be uncallable from Swift**: `secret_password_store_sync` and friends are
variadic C, measured against the installed header. In-process means the `*v_sync` variants, which take a
`GHashTable`, which means a second system-library target for glib-2.0, a `SecretSchema` built by hand and GError
plumbing -- around 200 lines and a new class of memory bug against 60 for `secret-tool`. **The swap back is
entirely inside that one file** if packaging ever objects to depending on a binary.

**The thing that had to be right: an exit code is not the answer.** `secret-tool` exits 1 both for a secret that
is not there and for a keyring it cannot reach, so an empty stderr is what tells them apart. Collapsing them is
the fault `DevicePINStore.Lookup` exists to prevent -- the app would rotate the PIN of a cube whose perfectly
good PIN it merely could not read. Verified against this machine's real keyring: twelve checks including
byte-exact round trips, a secret with trailing newlines, unicode, and `missing` rather than `unavailable` for an
absent item.

### 8 - Core - `CryptoKit` to a written SHA-256

**Done 2026-09-07, and not with swift-crypto.** `PortableSHA256` is 60 lines in the core; Darwin keeps CryptoKit
and only Linux calls it. The dependency was refused because `Package.swift` states it has none.

**It is compiled on both platforms and called on one**, so the Mac's `swift test` covers the code Linux depends
on, including a case asserting the two implementations agree at every length from 0 to 200. Verified against
published vectors, `sha256sum` over 201 inputs, and `hashlib` at the twelve lengths where the padding changes
shape. `architecture-ports-plan.md` settles it as a shim rather than a port, on the ground that the `#else`
branch is platform-free and already written, so a third platform needs nothing.

### 9 - Core - `Network` to a plain socket listener

**Done 2026-09-07.** `GoogleLoopbackListener` has two halves behind one interface: `Network` where there is
`Network`, Berkeley sockets where there is not. **The Darwin half moved across unchanged**, deliberately: it is
the path a real sign-in has used, and there was nothing to gain by rewriting it in sockets for the sake of one
implementation.

Three things the socket half had to get right, none of which the `Network` version shows:

- **`poll` with a timeout rather than a bare `accept`.** Closing a descriptor that another thread is blocked in
  `accept` on does not reliably wake it on Linux.
- **`bigEndian` rather than `htons`**, which is a C macro Swift cannot call. Same for the loopback address.
- **`SO_REUSEADDR`**, which is what `NWParameters.allowLocalEndpointReuse` asks for on the other side: a port
  left in `TIME_WAIT` by the previous sign-in must not refuse this one.

**Both halves are covered by the same five tests**, which drive whichever one they got over a real loopback
connection the way a browser would. Mutation-checked rather than assumed.

**This file is the last entry on `PlatformBlindCoreTests.adaptersStillInTheCore`**, and it cannot come off until
it is split in two.

### 10 - Linux - The BlueZ adapter

**Done, and proven on the cube 2026-09-13.** The radio is a port, and the protocol reasoning that used to sit
inside `BluetoothRadio` and `DeviceLogin` -- the command channel, the queue, the read-back matrix, which
commands can be confirmed at all -- is in `FacetCore` and is the same on both platforms. **What this slot owed
was transport.**

| Piece | What it does | Checked by |
|---|---|---|
| `SystemBus` | the whole of the libdbus interop: calls, marshalling both ways, signals | 7 tests against the real system bus |
| `DBusValue` | a D-Bus value as a plain Swift tree, so nothing above sees libdbus | the above, plus every tree test |
| `BlueZObjectTree` | the object tree read as records: adapters, devices, services, characteristics | 9 tests, hand-built trees |
| `BlueZRadio` | power, discovery, connect, disconnect, forget | run against the real cube |
| `BlueZGatt` | read, write, subscribe, and the value out of a signal | run against the real cube |
| `BlueZCubeGatt` | BlueZ's object tree behind the `CubeGatt` port | 22 tests against a fake transport |
| `BlueZCubeRadio` | `CubeRadio`: the scan window, the queue, the PIN candidates, the wait for `ServicesResolved` | 23 tests over a fake link |

**Everything above `SystemBus` is pure**, which is deliberate: the mistakes this layer makes are silent ones. A
UUID compared in the wrong spelling finds no characteristic and reports nothing missing, and a property read
without unwrapping its variant answers an empty array -- **which is a bug that happened**, caught by a test
rather than by a run: BlueZ wraps every property in a variant, so `Flags` and `UUIDs` came back empty until
`DBusValue.items` learned to see through one.

**Three ways `BlueZCubeGatt` differs from `CoreBluetoothGatt`, each of them BlueZ rather than a choice.** It
keeps **no characteristic table**, a BlueZ characteristic being an object path the tree can be asked for again
-- which says something about the Mac's, that table being CoreBluetooth's design showing through. Every answer
is **deferred by a wake of zero seconds**, because BlueZ's calls block where CoreBluetooth's do not and
`DeviceLogin` is written against a delegate that always answers later. And a refused subscription is **reported
rather than logged**, a subscription that silently did not happen being a cube whose face turns never arrive.

**The UUID expansion earns its keep.** The vendor's table lists the seven standard UUIDs in 16-bit shorthand,
CoreBluetooth accepts them that way, and **BlueZ never uses the shorthand at all** -- it reports
`0000180f-0000-1000-8000-00805f9b34fb` for what this app calls `180F`. `TimeFlipUUIDs.canonical(_:)` and
`match(_:_:)` are that expansion. Without it every characteristic lookup would find nothing, silently. **That
was three bugs in one when the GATT port landed**: eleven `==` comparisons, a `switch` over the four Device
Information UUIDs, and one hiding behind a local. Left in, the login would have found its characteristics,
presented no PIN and reported nothing. `InMemoryGatt` answers in the spelling a real adapter answers in for
exactly this reason.

**Which advertisement is a cube is `DeviceScanRules`, unchanged** -- the same rule CoreBluetooth's side asks,
so a renamed cube is found or lost identically on both platforms. Writing the probe taught its own lesson:
`ordered` is *ordering, not filtering*, so taking its first element answers an arbitrary device when nothing is
eligible at all. `isEligible` is the filter.

**Two calls are deliberately not made.** `Get`/`GetAll` are unused because `GetManagedObjects` answers the whole
tree in one call, and `InterfacesAdded` is not listened to because the scan reads the tree on its own clock --
libdbus dispatching into its own loop being the half that does not ask GLib and libdbus to share a file
descriptor.

**Neither `BlueZRadio` nor `BlueZGatt` has a hermetic test, and cannot**: both are I/O against a daemon and a
device. The suite covers everything they are built on, and what covers these two is a device run.

#### The transport is libdbus, in process

`CDBus` is a `systemLibrary` target over `dbus/dbus.h`, Linux-only in the graph exactly as `SQLite3` is.
**`pkgConfig: "dbus-1"` is load-bearing rather than tidy**: libdbus needs *two* include directories, the
arch-dependent `dbus-arch-deps.h` living under `/usr/lib/<triple>/dbus-1.0/include` while the rest is in
`/usr/include/dbus-1.0`.

**What made it possible is that none of the API this app needs is variadic.** `dbus_message_append_args` is, and
would have been uncallable from Swift exactly as libsecret's simple API was -- but the `dbus_message_iter_*`
family that replaces it is not, and that family is all of it. **One thing the importer cannot read**: the type
constants are `#define DBUS_TYPE_STRING ((int) 's')`, a cast it does not follow, so `SystemBus.Kind` spells them
out by value.

**A caller filters signals by what it asked for**, because not everything arriving is a match hit: the bus sends
`NameAcquired` to a new connection whatever it has subscribed to. Measured, not assumed.

What was measured before deciding, kept because it is what the decision rests on:

| Route | Works? | Cost |
|---|---|---|
| **`busctl` subprocess** for method calls | **Yes**, returns type-tagged JSON a `JSONDecoder` reads | Nothing to install |
| **`busctl monitor`** for signals | **No. Refused unprivileged**: `BecomeMonitor` answers `Access denied` on the system bus | -- |
| **`gdbus monitor`** for signals | **Yes**, unprivileged -- it adds match rules rather than becoming a monitor | Emits GVariant **text**, not JSON, so a notification value needs a parser of its own |
| **`libdbus-1` with a modulemap** | **Chosen** | Needs `libdbus-1-dev` |
| **The wire protocol in Swift** | Untried | No dependency, and the most work: SASL EXTERNAL, then marshalling |

**What decided it was where the notification values are read.** Face turns arrive as signals carrying a byte
array, which is the app's core function, and every subprocess route leaves that path depending on a parser of
human-readable output. libdbus hands the same bytes over typed. **That is the opposite conclusion to the
keyring's in item 7, and for a consistent reason**: there the subprocess won because the swap was contained in
one file and the values were strings; here the values are the point.

### 11 - Linux - The UI: filling the GTK slots

**The menu bar, the dialogues and the Settings window's first tab are done. Four tabs are not started.**

What exists in `Sources/FacetLinux`: the boot, the composition root, `MenuBar` (289 lines of GTK that decides
nothing), `GtkDialoguePresenter`, `GLibScheduler`, and -- as of 2026-09-16 -- `SettingsWindow` with the
**Categories tab** in it. The tray item draws the shared readout; its dropdown carries the cube's state, today's
totals per category, **Settings**, Pause, Lock and Quit; and pairing, pausing, unlocking and quitting a real cube
were all done through it on 2026-09-13.

#### All five tabs are built, and four of them were confirmed against a real cube (2026-09-16)

**The window carries Faces, Categories, Report, App and Device.** Three things the Mac has are deliberately not in
it, each because something else has to happen first rather than because it was skipped:

| Not built | Why | Who |
|---|---|---|
| The App tab's **Google section** | The sign-in needs a listener the core still picks for itself, which is item [16](#16---macos--linux---split-googleloopbacklistener) and then [15](#15---linux---google-sign-in-on-linux) | The Mac's half first |
| The Device tab's **rename control** | Its decision is inside `SettingsWindowController`, which this box cannot compile. Item [17](#17---macos---renamedevice-onto-devicesettingwrite) says plainly it is wanted the moment a Linux window wants the control. **This is that moment** | The Mac |
| The Device tab's **double-tap registers** | They have a second gate of their own and their one folding decision is struck in `architecture-ports-plan.md` | Here, later |

**A dead control is never drawn for either of them**, which is the same judgement `StatusItemMenu` already makes:
there is no section rather than one that cannot do anything.

**The factory reset was on that list for an hour and is not any more** (2026-09-16). It was left out because
`BlueZCubeRadio` had no path for one -- which was true, and the radio said so in its own doc comment, written when
this platform had no window to ask from. It has one now. What the reset took was transport and nothing else:
`DeviceLogin.factoryReset` sends `0xFF` and `CubeResetProof` decides what counts as proof, both already core
because neither is a question about CoreBluetooth or BlueZ. **Confirmed on the cube the same day**, and the trace
is the whole sequence: the command out, the link dropped because the cube rebooted, two attempts on the vendor PIN,
and `the cube let the app in on the vendor PIN, so the wipe took`. The tab then redrew itself to *Not paired* and
the Settings section went dead, which is the table being read back rather than the window assuming.

**What came out into the core, and every piece of it has tests it never had before**: `CategoryEdits` (30),
`FaceEdits` (14), `ReportReadout` (6), `AppSettingWrite` (6), `DeviceSettingRows` (7). All five were decisions
inside `SettingsWindowController`, reachable only through AppKit, so none of them had ever been tested on either
platform. [handover-mac.md](handover-mac.md) asks for each to be adopted.

**Found on the cube, and it is a fault on both platforms** (2026-09-16): writing auto-pause from the Device tab
sets the cube to the wrong value for three round trips before settling on the right one. The write confirms with a
`0x10` read, that answer reaches `DeviceSettingsSync.cubeReported(status:)` like any other status, and at that
moment the table still holds the old value -- because `DeviceSettingWrite` writes the table only *after* the cube
confirms, which is the ordering the first design rule requires. So the sync sees a disagreement it caused, corrects
the cube back, and the correction's own read-back starts the next round. It converges: cube 7m, table 7m, three
corrections later. **Neither radio makes this Linux-specific** -- `received(status:)` publishes every `0x10` answer
on both -- so the Mac has it too and no run has ever looked. Measured exchange in
[handover-mac.md](handover-mac.md) item 34.

#### The Settings window, and the Categories tab (2026-09-16)

**Confirmed on screen and driven over AT-SPI**, against a throwaway `XDG_DATA_HOME` so the cube and the real
database were not involved: create a category, pick an icon, pick a colour, re-pick the same colour to clear it,
set a daily limit, retire one (which cleared the face holding it), bring it back, and rename one through its
confirmation dialogue. Every one of those was checked twice over -- the control answered, and the row in
`category` says what it should. `Tests/Methods.md` Method 20 is how it was driven.

**The window is built on each open and destroyed on each close**, which is the one real difference from the Mac
and is `CLAUDE.md`'s first rule made structural rather than remembered. There the window and its five panes are
made once and reused, so the controller has to put every fold back to its default on each open and re-read every
setting into the panes; here there is nothing left to read from, so the next open reads the tables. **Measured
rather than argued**: with the window shut, `UPDATE category SET category_name = 'Renamed elsewhere'` behind its
back, and the next open through the tray showed the new name.

**What is in the core, and what is in GTK.** Every sequence a control sets off is `FacetCore.CategoryEdits` --
the icon, the colour, the name, the daily limit, retiring, reinstating, creating -- written once, covered by 30
hermetic tests, and the same module the Mac is asked to adopt in [handover-mac.md](handover-mac.md) item 31. What
is in `Sources/FacetLinux` is the drawing: `SettingsWindow`, `CategoriesPane`, `CategoryTable`,
`RetiredCategoryTable`, `CategoryCreateControl`, `EditableNameCell`, `IconGrid`, `ColourList`, `ColourSwatch`,
`PanelSection`, `SettingsWidgets`, `GtkSignals` and `ActivityIcon`. **That split is the whole point**: the tab
that will be drawn on a third platform is view construction, and nothing it has to decide is left to be decided
again.

**`PanelSection` is a `GtkExpander`, which answers two of `CLAUDE.md`'s requirements for free.** The heading sits
on the panel and the panel closes around it, because the style class is on the expander and its allocation shrinks
to the title row; and a hidden child takes no room in a GTK box, so there is nothing here answering to the Mac's
two swapped constraint sets. **The whole heading line is the target** on one condition -- the label has to be a
widget filling the title row, `facet_expander_set_label_widget`, or GTK sizes it to its text and the space after
the words is not the control.

**Three faults the accessibility tree could not see, and the screenshot could**, which is why Method 20 ends by
saying to look at the picture: the one tab read `...`, because the label was ellipsised and a notebook sizes a tab
to its label; every icon drew the no-icon glyph, because `.process` on a resource directory **flattens it** and
`Icons/Activities` exists nowhere in the bundle; and every category name sat 25px right of the *Name* caption,
because a `GtkButton` insets what it holds.

**The artwork is the Mac's own files**, reached through `Sources/FacetLinux/Resources/Icons`, a symlink to
`Sources/FacetMac/Resources/Icons`. A symlinked *directory* is followed when SwiftPM builds a resource bundle,
which is what the DDL already relies on. It is lopsided rather than wrong, and moving it belongs with item 13 --
[handover-mac.md](handover-mac.md) item 33 says so.

**`SettingsWindow.pane(for:)` is a switch over `SettingsTab`**, so a tab this platform has not built is a named
`nil` rather than a gap, and the notebook carries only the tabs that exist. Nothing is `nil` today.

#### Six faults the tree could not show, and a screen or a cube did

Each of these compiled, passed the hermetic suite, and was wrong. They are here because every one of them is a
thing a GTK port meets once.

1. **A notebook tab sized to an ellipsised label reads `...`** -- a label that has agreed to shorten itself has
   nothing to hold the tab open.
2. **`.process` on a resource directory flattens it**, so `Icons/Activities` exists nowhere in the bundle and every
   icon drew the no-icon glyph. The flat lookup is the one that answers.
3. **A `GtkButton` insets what it holds**, so every category name sat 25px right of its own caption. The
   `facet-flat` class is padding zero, and the Report tab's day cells need it too -- with the theme's padding each
   day demanded 46pt against the 39 the metrics worked out, and the window came up 730 wide instead of 640.
4. **`gtk_notebook_get_current_page` answers -1 until the pages are shown**, so reading the tables before that
   found no tab and every list came up empty.
5. **`switch-page` is emitted before the page changes**, so a handler asking the notebook which tab is showing is
   told the one being left. Switching to Report re-read Faces and the totals never arrived.
6. **Destroying a `PanelSection`'s widget leaves the Swift object pointing at freed memory**, and packing it again
   on the next draw is a use-after-free. The Device tab did exactly that, and **the app segfaulted the moment a
   real cube reported what it was** -- because that is the first thing that redraws that tab while it is open.

**The window says when a pane will not fit**, which is what found the third of those: a pane wider than
`SettingsMetrics.windowWidth` writes a `debug_log` row naming the tab and both numbers. Without it the only way to
tell which of five panes had widened the window was to take them out one at a time.

**`GtkDialoguePresenter` is 72 lines**, a `GtkMessageDialog` modal on a nested main loop the way `NSAlert.runModal`
is, with no parent window -- this platform's ordinary case and the Mac's nineteenth. **`wayOut` is simply honoured
here** where AppKit has to be worked around: GTK does not relocate a button by its title, so
`gtk_dialog_set_default_response` puts Return on the answer the core named.

**Two more variadic C functions are wrapped in `Sources/CGtk/shim.h`.** `gtk_message_dialog_new` and
`gtk_message_dialog_format_secondary_text` both take a printf format, which Swift cannot call. `"%s"` is passed
in C and the string travels as an argument, which is also the only safe way: a heading containing a `%` would
otherwise be read as a conversion.

**What is left is still a build rather than a slot.** `SettingsWindowController` is 3,206 lines of AppKit
and **there is no port to fill for it** -- `architecture-ports-plan.md` item 6 has one row outstanding and the
honest statement about the rest is that it is view construction and tab wiring, which is what an adapter is
*for*. So a Linux Settings window is built rather than slotted into, and **the decisions it makes that are
worth sharing should come out into the core as they are found**, which is the standing instruction in
[handover-linux.md](handover-linux.md) item 22 -- the one item on that side's list, and a warning rather than
a task. Two more decisions came out of the window after it was written (`ManualClock` and `CubeReports`), and
both are why the file keeps shrinking.


### 12 - Linux - The scripted suite on Linux

**Low priority, by the owner's instruction of 2026-09-16.** The suite is not to be edited and not to be run
until confirming a feature works genuinely requires it. That is the standing answer to anything below reading
as imminent: none of it is a job waiting to be picked up.

**What follows from that, because each has already come up once:**

- **A stale stamp is not an outstanding job**, and `All tests pass` being red is the expected state. Do not
  make it green by narrowing the pathspec, editing a stamp, setting `LINUX_IS_ADVISORY` or taking the check
  out of the workflow. A red check that is honest is worth more than a green one that is arranged.
- **Do not edit `lib.sh`, `run.sh`, `platform.sh` or a check script** as tidy-up or alongside unrelated work.
  A check that cannot be run cannot be validated, and editing this layer blind is what handover 23 and 24 cost
  in the other direction.
- **`swift test` is unaffected** and is still the thing to run on every change, on both platforms. A hermetic
  pass is not hardware confirmation, and a device-dependent change stays **unverified and deliberately so**,
  which is a different sentence from unverified by oversight and the one to write.

**Where it had got to, so that nothing is re-derived when it comes back.** The harness is further along than
the item has ever been, and none of this needs doing again:

- **`Tests/Scripted/platform.sh` has no unfilled Linux branch left.** `platform_not_yet` is still defined and
  is called from nowhere.
- **`scripts/tray-menu.py` drives the tray over D-Bus**, and `Tests/Methods.md` Methods 18 and 19 are written
  from real runs.
- **`platform_quit_app` quit a running app through its own tray menu on 2026-09-13.**
- **One known fault is deliberately left in place.** `lib.sh`'s `quit_app` never reaches `platform_quit_app`:
  `run.sh` calls the port, every check script calls the older copy, which clicks the status item and presses
  `quit-app` with `>/dev/null 2>&1` -- the swallowed failure `CLAUDE.md` names twice. It is
  [handover-mac.md](handover-mac.md) item 30, it is the Mac's to make because only a full run can exercise it,
  and under this priority it waits for that run rather than being fixed blind.
- **`scripts/check_interactive_checklists.sh` already asks for a Linux stamp**, reporting the absence rather
  than enforcing it (`LINUX_IS_ADVISORY=1`). Turning it on belongs in the same commit as the first passing
  Linux run, not before.

**Whether any of it can run headless is still the open question worth the most**, because it decides whether
CI could ever run this half at all. It costs one `xvfb` install and one check, and it is cheap enough to be
worth doing whenever the suite next comes up.

### 13 - Core - Repo restructure and the `CLAUDE.md` split

**Not started.** Agreed: one repo, shared core. About a third of the root `CLAUDE.md` is AppKit-specific and
would be worse than noise in a GTK session.

### 14 - Core - README

**Done 2026-09-16.** It opened *A native macOS menu bar application* and described one platform from there down.
It now says macOS is the app you can use today and that a Linux build exists and works, with what it does not
have yet named rather than implied: no Settings window, no Report tab, no Google sign-in.

**The Architecture section gained the thing it had never mentioned**: the three targets, and that each platform
capability is a port whose adapter its own `main.swift` injects. Three module lines were reframed around that
-- the status item is four core modules with a renderer per platform, the radio is reasoning in the core behind
a transport port with two adapters, and the Settings window is marked macOS only.

**It did not wait for item 13**, which was the plan when this item was written. The restructure is about
splitting `CLAUDE.md` and moving files; describing two platforms needed neither, and the README was wrong about
the project in its first line.

### 15 - Linux - Google sign-in on Linux

**Not started.** The listener is portable and tested on both halves (item 9), and `GoogleSignIn.run(open:)` is
the arm, taking the browser as a parameter rather than reaching for `NSWorkspace`. **Nothing in
`Sources/FacetLinux` names Google at all**: there is no `CalendarSync`, no `GoogleTokenStore`, and no slot filled
for opening a URL. The Linux equivalent of the browser is `xdg-open` through `Process`.

**It is a small item that depends on a large one.** On the Mac, signing in is a Settings-window control, so a
Linux sign-in wants either the Settings window from item 11 or a deliberate decision to put it somewhere else.
The flow has never been exercised end to end on this platform with a real Google account.


### 16 - macOS + Linux - Split `GoogleLoopbackListener`

**The one item with real work on both machines, and what empties the platform-blind allowlist.** The file is
365 lines holding two whole implementations behind one `#if canImport(Network)`: roughly 140 lines of
`Network.framework` and 200 of Berkeley sockets. Both work and both are covered by the same five tests
(item 9). **It is a port wearing an `#if`**, and it is the last entry on
`PlatformBlindCoreTests.adaptersStillInTheCore`.

- **The core** states the listener as a protocol: assign a port, wait for the code, answer the browser, cancel.
- **`Sources/FacetMac`** takes the `Network` half unchanged.
- **`Sources/FacetLinux`** takes the socket half unchanged.
- **Both composition roots** hand one over. `GoogleOAuthClient` constructs the concrete type today, which is
  the core choosing an adapter and the thing the rule forbids.

**Nothing is rewritten**, which is what makes it tractable: the two halves are already separated by the
conditional and already tested independently. **The Mac half is required for item 15**, because a Linux
sign-in cannot reach a listener the core still picks for itself.

### 17 - macOS - `renameDevice` onto `DeviceSettingWrite`

**The last unticked row of `architecture-ports-plan.md` item 6.** Seven of the eight Device tab settings writes
now go through `DeviceSettingWrite`, which is `CLAUDE.md`'s settings rule written once: the cube first, the
table only once the cube has taken it, the row put back on a refusal, and the three notices a result deserves.

**`renameDevice` / `sendRename` is the odd one and does not fit `send` as it stands**, because its read-back is
functional rather than a command: `0x15` has no answer of its own, and the confirmation is the GAP name
arriving a second or two into the next connection.

It is Mac work, and it matters to the port only when a Linux Settings window wants a rename control. **It is
also entangled with an open question**: whether a `0x15` rename moves BlueZ's `Name` the way it moves
CoreBluetooth's has never been measured.

### 18 - macOS - Confirm the read-back window on CoreBluetooth

**Answered 2026-09-16 from the trace, and the answer is no: CoreBluetooth never delivered into the window.**

**What the window was.** `CubeCommandChannel.isAwaitingResult` reported the *intention* to read rather than the
read, so a value arriving between writing the question and issuing the read was taken as the answer. On BlueZ
that is hit constantly, a `read` there producing the reply *and* a duplicate `PropertiesChanged` a few
milliseconds later. Fixed in `FacetCore` with a second flag set where the read actually goes out. The window
was shared, so the open question was whether the same two faults had been on the Mac unnoticed: every login
losing the cube's `0x10` state, and a quit reporting a refused auto-pause write the cube had in fact taken.

**Measured against `debug.sqlite` from scripted run 183**, a full 32-script run on the real cube on 2026-09-13,
10,767 rows. For every `0x10` write, the window is the interval between it and the `commandResult: read
requested` that fetches its answer:

| | |
|---|---|
| `command withResponse: 10` writes | **133** |
| of those, followed by a `commandResult: read requested` | **133**, none missing |
| command-result values landing **inside** the window | **0** |
| `0x10`-shaped answers whose most recent command-channel event was a *write* rather than a read request | **0** of 133 |

**The premise was checked, because a query that matches nothing answers nothing.** The gate pattern matches all
**701** command writes in the trace, so writes really were candidates for "most recent command-channel event"
and never won. Without that check the result would have been the shape of a test that fails open.

**One thing this does not say.** It is one trace, from one run, on one cube. It says CoreBluetooth did not
deliver into the window in 133 opportunities, not that it cannot. That is enough to answer the question that
was asked -- the two faults were BlueZ's and are not sitting unnoticed on the Mac -- and the fix costs this
platform nothing either way.

**The other half of [handover-mac.md](handover-mac.md) item 25 was a run of `51-device-connect`,
`55-device-settings` and `57-cube-pause`.** Not done, and it would re-measure what run 183 already recorded:
that run *is* those three scripts among the 32, and its trace is what the table above counts. Under item 12's
priority there is nothing here worth a fresh run.

### 19 - macOS - The history timer never restarts when a cube arrives late

**Raised by the Linux box as [handover-mac.md](handover-mac.md) item 28 and confirmed in the source on
2026-09-16**, and it is a Mac bug the Linux side does not have. That item ends *I have not touched `FacetMac`.
If I have read it wrong, say so here and I will take the item back* -- it read it right.

`HistoryTimer.start()` stands itself down when `hasSomethingToFollow()` is false, which at launch means no open
segment and `connection.connected` not set -- every launch whose cube is out of range at the time. The only
route back is `resumeIfStopped()`, and on the Mac the **only** caller is `settingsWindow.onTimingChanged`. None
of the eight paths that fires is a cube connecting: `radio.onLoginEnded` in `SettingsWindowController` shows the
pane, writes the pairing rows through `CubeReports` and stops there.

**So a Mac launch that finds its cube a minute later has a periodic history fetch that stays dead for the rest
of the session.** Not fatal, which is why it would never be noticed: `onCubeReady` fetches once when the link
comes up and `onFace` fetches on every turn. But `fetch_history_interval_seconds` is a safety net and it would
not be there.

**On Linux it is wired and visibly works**: `onLoginEnded` calls `historyTimer.resumeIfStopped()` after the
pairing rows, and the trace goes *History timer not started, nothing is being timed* at launch and *History
timer started, asking every 10s* the moment the cube is paired. **The fix is the same one line**, and it is the
Mac's to make because nothing here can exercise `SettingsWindowController`.

### 20 - macOS - Remove the twelve compiler artefacts at the repository root

**[handover-mac.md](handover-mac.md) item 27.** `AlertPresenter-2.d`, `.dia`, `.swiftdeps` and
`.swiftmodule`, and the same four each for `CoreBluetoothGatt-2` and `RunLoopScheduler-2`. **Tracked, not
ignored**, and they arrived in `db58b96` ("All nineteen alerts onto the port"): about 250 KB of intermediate
output from a macOS build that wrote into the working directory. Still present, confirmed 2026-09-16.

`git rm` on the twelve and a line in `.gitignore` is the whole of it, **unless the build that produced them is
still writing there**, in which case that is the thing to fix. It is the Mac's because they came off a Mac
build and only that machine can tell.

### 21 - macOS - Reconcile the `CLAUDE.md` scripted-suite wording

**Done 2026-09-16.** `CLAUDE.md`'s section said the suite was set aside and not to be asked for at all, which
is a freeze; the owner's instruction of the same day is a priority, leaving a door that wording closes. Run 183
on 2026-09-13 had already happened despite it.

The section is now *The scripted suite is low priority until the Linux port is finished* and says
so, gains the half the older wording did not have -- **do not edit the suite either** -- and names item 24 as
the fault that waits for a run. `architecture-review-2026-09.md` and `architecture-ports-plan.md` pointed at
the old title and now point at this one.

**[handover-mac.md](handover-mac.md) item 29 is what asked for this**, and it is answered rather than deleted:
deleting an item is its own commit under that file's protocol, and it is the Mac's to make.

### 22 - Linux - `SecretToolStore`'s doc comment describes an arrangement that is gone

`Sources/FacetLinux/SecretToolStore.swift:8` says `DevicePINStore` and `GoogleTokenStore` "keep their Darwin
bodies and branch to this at compile time". **Neither carries a `#if` any more.** The store moved out of the
core on 2026-09-10, `SecretStore` lost the `SecretStores.platform` that chose between the two, and both
composition roots hand an adapter over instead -- which is the arrangement `PlatformBlindCoreTests` exists to
enforce.

**The comment is fixed as of 2026-09-16.** It now says the store is handed over by `main.swift` and that
nothing above it knows which it got, and keeps what the old text was for as a record of what changed.

**The one thing left in that file was the Linux box's, and it is done 2026-09-16.** `SecretToolStore` opened
with `#if !canImport(Security)`, which was dead weight once the file lived in a target only Linux builds -- the
conditional was excluding it from a build it is never in. Its macOS counterpart `KeychainSecretStore` dropped
exactly that guard when it moved, and says why: *which square gets built is the manifest's business*. Removed
here, compiled and the 12 secret-store tests run, which is the check the Mac could not make.

### 23 - Core - The CI workflow's test counts are stale

`.github/workflows/tests.yml` says **"exactly 7 of the tests are Linux-only"** and **"1,064 tests -- 590 under
XCTest and 474 under swift-testing"**. Measured 2026-09-16: **77** are Linux-only, across six files guarded by
`canImport(CDBus)` or `canImport(CGtk)`, and the Linux run is **1,417**.

**The reasoning in those comments is still right and only the numbers have moved**, which is the argument for
correcting rather than deleting them: the job exists because running one test against two Foundations asks two
different questions, and that is more true at 1,340 shared tests than it was at 1,042.

**Done 2026-09-16**, comments only -- verified by diffing and finding no changed line that was not a comment.
The corrected block says the counts were re-measured and what they were before, so the next reader can see the
argument got stronger rather than wonder which figure to trust.

### 24 - macOS - `lib.sh`'s `quit_app` bypasses `platform_quit_app`

**[handover-mac.md](handover-mac.md) item 30, and Mac work that blocks item 12 outright.**
`Tests/Scripted/platform.sh` exists so a check says *quit the app*
and one file decides what that means. `run.sh` calls `platform_quit_app`; **every check script calls `lib.sh`'s
`quit_app`**, which clicks the status item and presses `quit-app` itself, both macOS-only:

    click_left || red "  could not click the status item to quit; falling back to a kill below"
    sleep 0.5
    python3 scripts/ax-press.py quit-app >/dev/null 2>&1

**The one the checks use is the older copy**, and that second line is the swallowed failure `CLAUDE.md` names
twice: a press that never happened does nothing and says nothing, and the wait after it then times out and
blames whatever it was waiting on. `platform_quit_app` already fixed exactly that on the macOS side.

**The change is two lines**: `quit_app` keeps `close_settings` and keeps the wait-then-kill, and the pair in the
middle becomes `platform_quit_app`. On macOS that is the same two calls in the same order with the reporting the
port already has.

**Why it is the Mac's**: `lib.sh` is 1,537 lines driving a real window, only a full run can exercise it, and
editing this layer blind is what handover 23 and 24 cost in the other direction. **`platform_quit_app`'s Linux
half is written and works** -- it quit a running app through its own tray menu on 2026-09-13 -- so this is the
single thing between the Linux box and running `01-launch.sh`, which is otherwise completely portable.

**Deferred with item 12** rather than fixed now, under the 2026-09-16 priority.

### 25 - Core - The auto-pause write sets the cube to the wrong value for three round trips

**Measured on both platforms, and it is shared code.** The Linux box found it on 2026-09-16 driving its Device
tab (`docs/handover-mac.md` item 34) and reasoned it could not be Linux-specific. **Confirmed here the same day
from `debug.sqlite`**, scripted run 183 on 2026-09-13, which contains four instances nobody had read. The cube
really is set to a value nobody asked for, and it narrates it:

    16:56:57.001  Auto-pause: sending 1m
    16:56:57.004  command withResponse: 05 00 01
    16:56:57.037  eventsData: autopause set
    16:56:57.105  commandResult: 02 02 00 01 ...
    16:56:57.106  The cube confirms it took: auto-pause 1m
    16:56:57.110  Telling the cube auto-pause 0m (the cube says its auto-pause is 1m and the table says 0m)
    16:56:57.111  command withResponse: 05 00 00
    16:56:57.113  Auto-pause: the table now holds 1m
    16:56:57.152  eventsData: autopause OFF          <- the hardware, set to what nobody asked for
    16:56:57.199  Telling the cube auto-pause 1m (the cube says its auto-pause is 0m and the table says 1m)

**No single step is wrong, which is what makes it worth writing down.** `DeviceSettingWrite` writes the table
only after the cube confirms, which is the ordering the first design rule requires. The confirmation is a `0x10`
read. Every `0x10` answer reaches `DeviceSettingsSync.cubeReported(status:)`, including the one this write asked
for -- and at that instant the table still holds the old value, so the sync sees a disagreement it caused and
corrects the cube back to it. Its own read-back then starts the next round the other way.

**It converges after three corrections**, which is the only reason it is not urgent. What it costs is three extra
round trips per write and a window in which the hardware holds a value nobody asked for.

**The fix wants item 35 first, and that is the finding rather than a deferral.** The honest version is the sync
ignoring a status while a write of that setting is in flight, and there is nowhere good to put that flag today:
`DeviceSettingWrite` is a static enum holding no state, so the bracket belongs to whatever starts the write. On
Linux that is `DeviceSettingRows` in the core; on the Mac it is still `SettingsWindowController`'s own copy. **Two
surfaces bracketing a shared flag two different ways is the hazard this would be fixed to avoid**, so adopting
`DeviceSettingRows` (item 35 of `docs/handover-mac.md`) comes first and then there is one place to change.

**Whoever fixes it owes both radios a run**, this being shared code that changes what goes to the hardware. The
Linux box has offered its half; the Mac's is `55-device-settings` and `65-auto-pause`.

---

## Open questions

| Question | How to answer it |
|---|---|
| **Can the scripted suite run headless?** `xvfb` is not installed and this box has no passwordless `sudo`. It decides whether CI could ever run the Linux half of `Tests/Scripted/`, which it can never do for the Mac | Install `xvfb`, run one check under it. **The highest-value question here**, and cheap, but it waits with item 12 rather than being a reason to reopen the suite |
| **Does a `0x15` rename move BlueZ's `Name` the way it moves CoreBluetooth's?** `BlueZRadio.scannedDevices` maps that one property to **both** `peripheralName` and `advertisedName`, so `DeviceScanRules.isEligible` and `DevicePairingRules.adoption` see one name where the Mac sees two that a rename moves at different times (finding 1). Nothing has ever measured it | Rename from the Mac with the cube in range of both, and read the scan from Linux. `BlueZCubeGatt` reports a device `PropertiesChanged` as `nameArrived`, so a rename made while Linux holds the link has somewhere to show up. **Cannot be answered from the Linux box alone**: renaming is a Device tab control, and while this platform has the tab as of 2026-09-16 it has no rename control on it -- that decision is still inside `SettingsWindowController`, which is item [17](#17---macos---renamedevice-onto-devicesettingwrite) |
| **Does the rename apply immediately or is it deferred?** Open since August; finding 1 wants a second BLE central with no cached record, and this box is one | Rename from the Mac, read the GAP name from Linux |
| **Does the `T.Flip` manufacturer data survive a rename?** If it does, a renamed cube has two stable markers | Rename, then re-read `ManufacturerData` |
| **Does CoreBluetooth ever deliver into the read-back window?** The duplicate-read fault above was BlueZ's trigger, and the window is in shared code. If it does, the same two faults are on the Mac and nobody has noticed | [handover-mac.md](handover-mac.md) item 25: a run of `51-device-connect`, `55-device-settings` and `57-cube-pause`, and a look at whether any `0x10` on the Mac ever answered without a `commandResult: read requested` before it. That last part is answerable from a trace already held, with no cube |
| **Does Darwin hand back a `TZ` that corelibs refuses?** `TimeZone.current.identifier` echoes a legacy IANA name verbatim on both platforms (`TZ=Cuba` answers `Cuba`), which is why `timezone` is seeded and read through `timezone_lookup`. But `TZ=AEST` is **refused** on Linux and falls back to the system zone, while an `AEST` row reached the Mac's `test.sqlite` somehow | Question 4 in [systems-info.md](systems-info.md), where the answer lands |
| **Is `contentsOfDirectory(at:)` on a symlink a corelibs bug or intended?** Narrowed 2026-09-07 to a symlinked *directory* only, so a report has a sharp case | Check the swift-corelibs-foundation tracker |

**Retired, and worth saying why rather than deleting.** *Does the core build on Swift 6.0?* was asked because
this file believed the Mac built with 6.0, read off `swift-tools-version: 6.0`. That line is the manifest and
language level, not the compiler. The Mac builds with 6.3.3, Linux uses 6.2, and no machine has 6.0 or wants
one. `installation.md` states 6.0 as a **minimum**, which both satisfy.

---

## CI runs the suite on both platforms

**Decided 2026-09-09. Every test runs in CI, on every platform that can run it.** Not the Mac's suite with
Linux checked by hand, and not a Linux job that runs only the Linux-specific parts.

**Why both, when most of the tests are the same tests.** Because the overlap is the product rather than the
waste. There is no `#if os(Linux)` anywhere in `Sources/` and only 77 of the tests are Linux-only, so a plan of
"test everything on the Mac, test the Linux-only parts on Linux" would leave 1,340 shared tests running against
one Foundation only. Those are where both platform divergences found so far actually lived: a `Timer` on
`RunLoop.main` that never fires because a `@MainActor` swift-testing test is not on the main thread here, and
`FileManager.contentsOfDirectory(at:)` returning an empty array for a symlinked directory. Both are shared code
passing on one platform and failing on the other. **Running one test against two Foundations asks two different
questions**, so coverage is a property of test x platform rather than of the test list.

### The numbers

| | Tests | |
|---|---|---|
| Every test in the repository | **1,962** | 1,885 the Mac can run, plus the 77 Linux-only |
| macOS runs | **1,885** | measured 2026-09-16: 1,225 XCTest, 660 swift-testing, 0 failures |
| Linux runs | **1,417** | 680 XCTest, 737 swift-testing. **Derived by counting, not run today**; the Linux box's own last report was 737, which is that swift-testing figure exactly |
| Linux CI runs | **1,415** | the two adapter-bound bus tests are skipped by name |
| Mac-only, not yet on Linux | **545** | the 32 files `Package.swift` excludes, every test in them XCTest |

**The 545 close as item 11 lands**, and they are itemised rather than estimated: every one of the 32 files needs
AppKit, CoreBluetooth or a `FacetMac` type. **`EveryLinuxExclusionEarnsItsPlaceTests` is what keeps that
honest** -- a file whose subject has moved into the core stops needing the platform, and the entry would
otherwise stay behind because nothing asks it to leave. A file sitting there needlessly is a suite that silently
does not run on Linux, which is the one failure this whole exercise is about.

**Only 2 of the 7 bus tests are really hardware-bound, and that is measured rather than reasoned.** The job
skipped the suite whole to begin with. `SystemBus.init` calls `dbus_bus_get(DBUS_BUS_SYSTEM)`, libdbus reads
`DBUS_SYSTEM_BUS_ADDRESS`, so **a private `dbus-daemon` on any machine reproduces a runner's bus** -- one with
no BlueZ on it -- and the suite can simply be pointed at it. Five pass there; two look for a real
`org.bluez.Adapter1` and belong with `Tests/Scripted/`, their absence being a fact about the machine rather than
about the code.

**`aByteArrayArgumentIsAcceptedByTheWire` passes for a different reason in CI than on a developer's box.** It
asserts only that the call is refused, and both conditions refuse:

    no BlueZ      org.freedesktop.DBus.Error.ServiceUnknown   -- the bus, because nothing owns the name
    BlueZ present org.freedesktop.DBus.Error.UnknownObject    -- BlueZ, about the object path

In CI it therefore proves libdbus marshalled the byte array and put it on the wire, which is its stated claim,
but it stops at the bus and proves nothing about what BlueZ accepts. Asserting *which* error would make it
honest on both machines and is the obvious improvement, but it changes what the test claims, so it is noted
rather than done.

### The container runs as root, and one test is right to fail there

**Measured 2026-09-09**, running the job's steps in `swift:6.2-noble` under `podman` rather than on the box. It
went red on nothing to do with D-Bus:

    DevicePINSourceTests.testAFileThatWillNotGiveUpItsCopyIsNotReportedAsSettled
      settleAtLaunch() -> .clearedARedundantCopy, expected .nothingToSettle

**Because root ignores mode bits.** That test sets a config file to `0o400` so the write is refused, and asserts
the app does not then claim to have settled. A container job runs as root unless told otherwise, so the write
succeeded and the test failed against an app doing exactly the right thing.

**This is the second time that same test has been broken by a platform declining to enforce a permission**, the
first being `.immutable`. The shape is worth keeping even though the cause differs: **a test whose premise is a
refusal fails against correct behaviour wherever the refusal does not happen**, and it looks like an app bug
both times.

So the job makes an unprivileged `ci` user, hands it the workspace, and runs both `swift build` and `swift test`
through `su ci`; only `apt-get` stays root. The bus daemon is started by `ci` too, so the socket belongs to
whoever connects to it.

**Two smaller things the run settled.** The `swift:6.2-noble` tag is **6.2.4**, confirmed from the image rather
than from a tag list, against 6.2.0 on the Linux box -- same language version, different compiler, and the first
thing to check if CI ever fails where a hand-run passes. And swift-testing finished about ninefold faster in the
container than on that box, with no cause established; it is not BlueZ, since a private bus there was equally
slow. Recorded as an observation rather than a finding.

**CI had never run this branch before 2026-09-09**, which is why a bug this old surfaced then: the workflow
fires on `pull_request` or a push to `main`, and this branch had had neither in 96 commits. The bug was
`DeviceEventRecorderTests` comparing a stored zone against `TimeZone.current.identifier`, where a runner on
`GMT` stores the canonical `Etc/GMT`; it had only ever passed because both development machines sit in
`Australia/Brisbane`. **Worth remembering as a property of the arrangement rather than of that bug: a long-lived
branch with no pull request is a branch CI has never seen.**

### What is still red, and why

**`All tests pass` is red, and honestly so.** All four test jobs pass. The scripted-suite gate does not:
`Tests/Scripted/last-run-mac.md` records run 183 at `637628b` -- 793 of 793, clean tree, 2026-09-13 -- and seven
watched files have changed since, six of them on the Linux side.

**Do not make it green** by narrowing the pathspec, editing a stamp, setting `LINUX_IS_ADVISORY` or taking the
check out of the workflow. `CLAUDE.md` is explicit: a red check that is honest is worth more than a green one
that is arranged. One full run clears whatever has accumulated, so nothing is lost by the wait.

**Red is the expected state and is not a job.** The owner set the scripted suite to low priority on
2026-09-16: it is neither edited nor run until confirming a feature genuinely needs it. So this gate stays red
for as long as the port is the work, and saying so is the whole of what is owed. **The four `Test (...)` jobs
are the signal that means anything right now.**

**The wording it superseded is corrected** (item 21, done 2026-09-16). `CLAUDE.md` had said the suite was set
aside and not to be asked for at all, which is absolute where this is a priority, and run 183 happened on
2026-09-13 despite it. The practical difference is narrow but real: a run is available when a feature genuinely
cannot be confirmed any other way, which is the case [handover-mac.md](handover-mac.md) item 25 is making.

**A note on how a gap like this gets worded, because the wording was once the fault.** `systems-info.md`
recorded *nothing in CI compiles the project on Linux today* as a fact, dated and accurate, sitting in a table
of facts. It was true and it was the wrong shape: a gap stated in the indicative reads as a condition to work
around, where the same thing put as a question -- should CI run the Linux tests as well? -- gets answered in an
afternoon. It had been true for a month. **Where this file records something the port cannot do yet, it should
say what would close it and whose call that is.**

---

## Decided: one process, Swift calling GTK3 through a modulemap

**Settled 2026-09-09 by the owner, and built since.** The candidates were one process in Swift + GTK3, or two
processes with a Python/GTK3 tray over SQLite as the IPC; this file recommended the second on the grounds that
Swift GTK *bindings* target GTK4 while MATE is GTK3.

**What retired that risk is that no binding is involved.** `Sources/CGtk` is a `systemLibrary` target over the
system's own GTK3 and `libayatana-appindicator3`, which is the pattern this package already uses twice -- for
`SQLite3` and for `CDBus` -- so there is nothing to keep in step with anybody's release schedule. **One
`pkgConfig`, not two**: `ayatana-appindicator3-0.1` declares GTK as a dependency, so asking pkg-config for it
yields GTK's four include directories as well, two of them arch-dependent.

The awkwardness C imposes is real but small and answered in `shim.h`: **GTK's casts and `g_signal_connect` are
macros**, which Swift's importer leaves behind, so `static inline` helpers do them in C where the macro works
and the type check survives. That is the same coin as `CDBus`'s variadic problem, and both are best answered in
one small file rather than at every call site.

**What the two-process design would have cost, now that it is not being paid**: a second language, a second
process for `Tests/Scripted/` to launch and quit, `InstanceLock` becoming per-process rather than per-app, and
care over WAL mode with a busy timeout. `platform.sh` assumes one `BINARY`, and it is right to.

**GTK3 is not thread-safe, and `MenuBar` is `@MainActor` because of that rather than because of the compiler**:
every call has to come from the thread that called `gtk_init`, and `gtk_main` runs its loop on that same thread.
The isolation is what was already true, written down where the compiler can hold us to it.

It needs `libgtk-3-dev` and `libayatana-appindicator3-dev`, which `Package.swift` names in the target's
`providers` so the next machine is told rather than left to work it out.

---

## Reproducing

```sh
export PATH="$HOME/.local/swift/swift-6.2-RELEASE-ubuntu24.04/usr/bin:$PATH"

swift build                  # the core, FacetLinux, and the three system-library targets
swift test                   # 1,417 tests here, 1,885 on the Mac

.build/debug/FacetLinux      # the app: tray item, cube, database

# The cube with no app in the way. Quit Facet on both machines first -- one connection at a time.
python3 scripts/linux-ble-probe.py

# The tray, without a mouse
python3 scripts/tray-menu.py                  # every line, with whether it is sensitive
python3 scripts/tray-menu.py --press "Quit"   # choose one, by label
```

**The original compile-and-test spike is not committed**, being a measurement rather than an artefact. It was
assembled by computing the closed set of source files, copying them to a scratch package with a hand-written
sqlite modulemap, applying the three Foundation fixes, and adding the test files that referenced only
closed-set types. Everything it established is above, and everything it built has since been replaced by the
real targets.
