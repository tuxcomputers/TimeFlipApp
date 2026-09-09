# Architecture review, September 2026

[← Back to README](../README.md) · [The Linux port →](linux-port.md) · [FacetCore split →](facetcore-split.md) · [State Reference →](state-reference.md)

**The visual version of this review, with the before-and-after diagrams, is at
<https://claude.ai/code/artifact/731293b8-2445-4cdf-9afa-2c7aa1268cb1>.** This file is the durable copy: it
holds every finding and every measurement, and it is the one that syncs to both machines. The diagrams are
the only thing that lives solely at that link.

**Nine candidates for making modules deeper**, found on 2026-09-09 against `ea4c4e6` on `feature/linuxPort`,
with a clean tree. Scoped to the Linux port because that is where the last sixty commits are. Nothing here has
been acted on, and nothing here is a decision: it is a list of places where a small interface would buy more
than the one that is there now, ordered as found rather than by priority. The sequence worth doing them in is
at the end.

The vocabulary is deliberate and is used the same way throughout. A **module** is anything with an interface
and an implementation. Its **interface** is everything a caller has to know: the signature, but also the
ordering constraints, the error modes and the invariants. A module is **deep** when a lot of behaviour sits
behind a small interface, and **shallow** when its interface is nearly as complex as what is inside it. A
**seam** is a place where behaviour can be changed without editing in that place, and an **adapter** is a
concrete thing that satisfies a seam. Depth buys **leverage** for callers and **locality** for whoever
maintains it.

**How the claims were checked.** Every number was counted against the tree rather than estimated, and the
counts that carry a candidate were then re-checked by hand. Where a count is quoted below, the command that
produced it is quoted with it, so it can be re-run rather than believed.

---

## The reference point is already in this repository

`CubeLock`, `FaceColourSync` and `DeviceSettingsSync` each take the command channel as a closure:

```swift
private let send: (Data, @escaping (Bool) -> Void) -> Void   // CubeLock.swift:21
private let isCubeConnected: () -> Bool                      // CubeLock.swift:24
```

That one seam buys 1,454 lines of hermetic tests over 21 command sequences, with no cube and no radio:
`CubeLockTests` 296, `FaceColourSyncTests` 350, `DeviceSettingsSyncTests` 293, `HistoryIngestorTests` 515.
`DeviceSettingsSyncTests` builds the whole adapter in 18 lines.

**Every candidate below is measured against that.** The dividing line in this codebase is exact: a module
whose radio dependency is `(Data, @escaping (Bool) -> Void) -> Void` is tested, and a module that holds a
`CBPeripheral` or a `CBCentralManager` is not.

`DebugLog` is the other reference point, for interface size rather than for seams: a three-member interface
(`init`, `setRecording`, `record`) over 416 lines, serving 345 call sites in 23 files.

---

## The measurements this review rests on

```sh
# 2.6%: of the two macOS radio modules, the part that is actually CoreBluetooth
for f in Sources/FacetMac/BluetoothRadio.swift Sources/FacetMac/DeviceLogin.swift; do
  code=$(grep -vE '^\s*(//|/\*|\*|$)' "$f" | wc -l)
  cb=$(grep -vE '^\s*(//|/\*|\*|$)' "$f" | grep -cE '\bCB[A-Z][A-Za-z]*')
  echo "$(basename $f): $cb of $code"
done
# BluetoothRadio.swift: 16 of 695
# DeviceLogin.swift:    24 of 825

# the nine FacetCore modules no test file names at all
for f in Sources/FacetCore/*.swift; do
  b=$(basename "$f" .swift)
  [ "$(grep -rl "\b$b\b" Tests/FacetTests/ | wc -l)" -eq 0 ] && echo "$b"
done
```

| Measurement | Value |
| --- | --- |
| `FacetCore` | 96 files, 14,675 lines |
| `FacetMac` | 35 files, 16,145 lines |
| `FacetLinux` | 2 files, 336 lines |
| Of the two macOS radio modules, lines touching a `CB*` symbol | **40 of 1,520 (2.6%)** |
| `FacetCore` modules no test file references | **9 of 96** |
| Test files excluded from the Linux build | 48 files, 13,666 lines, 852 tests |
| Of those, not AppKit-bound in substance | **~3,500 lines (26%), ~240 tests** |

The nine unreferenced modules cluster into exactly two groups, and the grouping is the finding: the
credential stores (`DevicePINStore`, `GoogleTokenStore`, `SecretToolStore`, `GoogleCalendarClient`,
`CalendarSync`) and the BlueZ radio (`BlueZRadio`, `BlueZGatt`, `CubeRadio`, `CubeStates`). Both groups are
untested for one reason: the module reaches its dependency through a hard static or a concrete class instead
of through a seam.

---

## The candidates

### 1. Put the radio seam below the sequencing, not above it

**Strong.** `Sources/FacetMac/BluetoothRadio.swift` (1418), `DeviceLogin.swift` (1482),
`Sources/FacetCore/BlueZRadio.swift` (227), `BlueZGatt.swift` (121).

**40 of 1,520 code lines in the two macOS radio modules touch a CoreBluetooth symbol.** The other ~1,480 are
protocol sequencing that could sit in `FacetCore`:

- The command channel: `isCommandInFlight` (`DeviceLogin.swift:544`), `enqueue` (`:571`),
  `armCommandDeadline` (`:593`), `acknowledgedCommand` (`:611`), `askedForConfirmation` (`:638`), `answered`
  (`:651`), `finishExchange` (`:683`). ~170 lines, pure sequencing over `Data`, and the module that makes
  `DeviceCommandRules.readBack` correct.
- The reach and candidate order: `ReachTarget` (`BluetoothRadio.swift:734`), `tryNextCandidate` (`:492`),
  `endReach` (`:530`), `end(_:_:)` (`:1022`), `retry()` (`:990`). ~180 lines, no CoreBluetooth in the
  decisions.
- The factory-reset proof: `ResetConfirmation` (`:260`), `factoryReset` (`:841`),
  `retryResetConfirmation` (`:886`), `endReset` (`:906`). ~120 lines.
- The history fetch: `HistoryFetch` (`DeviceLogin.swift:159`), `request` (`:454`), `received(historyFrame:)`
  (`:497`). ~90 lines.
- The PIN rotation machine: `Step` (`:57`), `loggedIn` (`:1021`), `confirmationAnswered` (`:1079`).

None of it has a unit test, and none of it can get one through the current interface:
`DeviceLoginRulesTests.swift:9` states the block outright, that a `CBPeripheral` cannot be built outside
CoreBluetooth. All of it is verified only by `Tests/Scripted/50`-`66`, against real hardware, with a person
turning the cube.

**And it is budgeted to be written twice.** `linux-port.md` item 10 reads "Roughly 600-1000 lines behind the
interface `BluetoothRadio` already presents". That is the cost of rewriting the list above. `BlueZRadio`
covers discovery and the link; `BlueZGatt` covers read, write and notify. Neither has a PIN, a login, a
command queue, a read-back, a history fetch, a reset proof or a candidate order.

**The proposal.** Move the sequencing into `FacetCore` behind a seam of write, read and subscribe, which is
the shape `BlueZGatt` already has (`:32`, `:51`, `:70`, `:104`) and the shape `CubeLock` already proves. The
macOS adapter becomes the ~40 lines that genuinely need CoreBluetooth; `BlueZGatt` becomes the second adapter
without being rewritten; an in-memory adapter makes the whole of the above hermetic.

**What it must not break.** The read-back discipline in `CLAUDE.md` currently lives inside `DeviceLogin`, and
two measured traps have to survive the move: a `0x10` answer carries no echoed command byte, so it is
trustworthy only when read strictly after its own acknowledgement; and a locked cube reports itself paused
whatever its pause byte says, so pause is confirmed before the lock is sent.

### 2. `CubeRadio` is a hypothetical seam

**Strong, and done on 2026-09-09. The seam is real now, and the diagnostic it was meant to yield came back negative -- see the end of this section.**

**Strong.** `Sources/FacetCore/CubeRadio.swift:11-37`, `DeviceReconnector.swift:30` and `:99`,
`Tests/FacetTests/DeviceReconnectorOfferTests.swift:63`, `Package.swift:61`.

The seam was cut in stage 1c of the FacetCore split, and `facetcore-split.md:66` says what it was for: "It
also makes the reconnector testable without a radio, which it currently is not."

Three things are true of it today:

- **One adapter.** `BluetoothRadio.swift:46` is the only conformance in the repository.
- **No double.** Grepping `: CubeRadio` across `Tests/` returns nothing, so the leverage the split promised
  was never collected.
- **The test bypasses it.** `DeviceReconnectorOfferTests.swift:63` constructs
  `radio: BluetoothRadio(debugLog: nil)`, a concrete macOS class, for a module that depends only on the
  protocol. That is why the file is on the Linux exclusion list at `Package.swift:61`.

`BlueZRadio` shares **none** of the six members. `CubeRadio` is async, UUID-based and carries state flags
(`connectedDevice`, `isScanning`, `isReachingForCube`, `isFactoryResetRunning`, `reach`,
`forgetWhatWasFound`); `BlueZRadio` is synchronous, throwing and address-based (`powerOn`, `startDiscovery`,
`scannedDevices`, `connect(address:)`, `disconnect(address:)`, `forget(address:)`).

Applying the deletion test: delete `CubeRadio` today and nothing changes, because nothing uses it
polymorphically. One adapter is a hypothetical seam; two would make it real.

**The proposal.** Write the in-memory adapter the split intended. Five members. It takes the file off the
exclusion list and reaches `attempt()` (`DeviceReconnector.swift:126`) and `scheduleAttempt()` (`:264`),
neither of which any test drives.

#### What was done, 2026-09-09

`Tests/FacetTests/InMemoryCubeRadio.swift`, 64 lines, is the second conformance. **Six members, not five** --
the protocol's own comment said five and was one out, `forgetWhatWasFound` having been added without the count
moving; that is corrected. Applying the deletion test again now fails, which is the point: two adapters make it
a seam.

- **`DeviceReconnectorOfferTests` is off the exclusion list**, 37 files there now rather than 38, and it no
  longer builds a concrete macOS class for a module with no platform dependency. It kept its 15 tests and
  gained the ability to assert `forgetWhatWasFound`, which it could not see before.
- **`attempt()` is internal**, which is all it needed -- unlike the three `fire()` extractions of the same day
  it was already the timer's whole body, so only the `private` was in the way.
- **`DeviceReconnectorAttemptTests`, 14 tests**, drives `attempt()` and `scheduleAttempt()`. Mostly it asserts
  the first rule in `CLAUDE.md`, which this module's doc comment is emphatic about and nothing checked: the
  device, both names, the candidate PINs and the rotation target are read from the table *per attempt*, so a
  rename lands on the next try and a forget stops the loop. A loop reading stale values looked identical from
  outside until there was a double to record the arguments twice.
- **The rotation target is the one that would have bitten.** `rotatingTo` is a closure because a release build
  picks six random digits each time, so a captured target would put the same PIN on every cube a launch met.
  Nothing tested that; a captured value passes every other test in the file.
- **Mutation-tested rather than assumed.** Three deliberate breaks -- capture the rotation target, stop passing
  the radio's `isScanning` through, read the remembered name from a literal -- were each caught by the
  intended test. A suite that passes first time is worth checking bites.

**The diagnostic came back negative, and that is a result.** *The sequence worth doing them in* proposed this
as the cheap evidence for candidate 1: "if `DeviceReconnector` proves awkward to drive through those five
members, that is the cheapest possible evidence that the seam is in the wrong place." It was not awkward. The
six members were exactly what the loop needed, the double took 64 lines, and nothing had to be contorted to
drive either private path.

**What that does and does not say about candidate 1.** It does not weaken it, because the two are seams for
different things: `CubeRadio` is the seam for the *reconnect loop*, and candidate 1 is about the seam under the
~1,480 lines of *protocol sequencing* in `DeviceLogin` and `BluetoothRadio`, which `CubeRadio` does not touch.
So this exercise says the reconnect seam is in the right place and offers no evidence either way about the
sequencing one. Candidate 1 has to be argued on its own terms rather than inheriting a verdict from here.

### 3. One secret store, four copies of its answer

**Strong.** `Sources/FacetCore/SecretToolStore.swift` (131), `DevicePINStore.swift` (144),
`GoogleTokenStore.swift` (136), `GoogleAccountRules.swift:71`, `DevicePINSource.swift:21-22`.

Four structurally identical three-case types:

| Type | Cases |
| --- | --- |
| `SecretToolStore.Answer` | `found(String)` / `missing` / `unavailable(Int32)` |
| `DevicePINStore.Lookup` | `found(String)` / `missing` / `unavailable(Int32)` |
| `GoogleTokenStore.Lookup` | `found(String)` / `missing` / `unavailable(Int32)` |
| `GoogleAccountRules.Credential` | `present` / `missing` / `unavailable` |

The doc comment on the `unavailable` case is copied word for word between the middle two, down to the
sentence explaining why it is `Int32` and not `OSStatus`.

**Two callers independently invented their own way around the missing seam**, which is the strongest evidence
that it is wanted:

- `DevicePINSource.swift:21` injects closures: `var keychainLookUp: () -> DevicePINStore.Lookup = { … }`.
- `GoogleAccountRules.swift:69` mirrors the type, and says why: "A straight mirror of
  `GoogleTokenStore.Lookup`, kept as its own type so this file can be reasoned about, and tested, without a
  Keychain anywhere near it."

Meanwhile the callers that did neither cannot be tested at all: `GoogleCalendarClient.swift:61` and
`SettingsWindowController.swift:321` both switch on `GoogleTokenStore.lookUp()` directly.

Each of the two stores carries the same four members (`save`, `lookUp`, the convenience reader, `clear`) with
an `#if !canImport(Security)` branch inside each, six branches in all, every one of them translating one
three-case enum into another. Neither store has a single test.

**The proposal.** One `SecretStore` module with one `Lookup` type and a service/account key. Keychain and
`secret-tool` become adapters at a runtime seam rather than compile-time branches inside every method, and an
in-memory adapter gives 411 untested lines a test surface. Two adapters already exist, so the seam is real
rather than hypothetical.

### 4. The daily limit is one fact asked five ways

**Strong.** `ManualTimerRules.swift:111`, `PauseMenuRules.swift:62`, `StatusItemClickRouter.swift:80`,
`CubeLock.swift:135` and `:235`.

`CLAUDE.md` says the limit is "decided by four separate expressions in four files". That is accurate, and it
is an undercount.

| Where | The expression |
| --- | --- |
| `ManualTimerRules:111` | `!(timingState == .paused && isLimitReached)` |
| `PauseMenuRules:62` | `!(isLimitReached && cubePauseState == .paused)` |
| `StatusItemClickRouter:80` | `!(action == .toggleCubePause && isLimitReached && cubePauseState == .paused)` |
| `CubeLock:135` | `!(wanted == false && startingIsRefused())` |
| `CubeLock:235` | the same again, inside `resume()` |

The last two say `wanted == false` where the others say `cubePauseState == .paused`. Same rule, different
words. Two more decide the same fact for display: `StatusItemTitle.swift:216` and `TimingView.swift:217`.

**The tested part was never the risk.** `DailyLimitEnforcement.isLimitReached(totalSeconds:limitMinutes:)` is
three lines with 274 lines of tests, and the live bypass on 2026-08-27 did not touch it. What was wrong was
which paths ask: `PauseMenuRules.swift:53` records it verbatim, that `ManualTimerRules.isClickable` answers
about the app's own clock and "a cube leaves that `.idle` however busy it is, so every cube click fell
straight past the only place the limit was consulted". `CubeLock.swift:223` records the fifth path the same
way: lock the cube and unlock it again, and the limit was gone.

**The proposal.** One module answering "may this pause be lifted", taking `cubePauseState` and `timingState`
together so the cube and the app's own clock cannot be asked separately and disagree. The seam moves from
around the arithmetic, which was never in doubt, to around the set of paths obliged to ask.

`state-reference.md` already names this fact `isLimitReached` and says "Naming it does not merge them; it
makes the fact that they have to agree visible." This is the merge that note defers.

### 5. The link lifecycle is three hand-written lines

**Worth exploring.** `Sources/FacetMac/main.swift:633-650`, `HistoryIngestor.swift:162`,
`FaceColourSync.swift:197`, `DeviceSettingsSync.swift:211`.

```swift
radio.onLinkEnded = { _ in
    historyIngestor.linkEnded()
    faceColours.linkEnded()
    deviceSettings.linkEnded()
}
```

Each of the three documents a stall that shipped. `HistoryIngestor.swift:155`: "the fetch stayed in flight for
the life of the process, so every later refresh was refused and the app ingested no history again until it was
relaunched." `FaceColourSync.swift:206`: "a flag left true makes `run` return early for the rest of the
launch. Every connection after it would queue twelve faces and send none."

All three are individually tested. **The completeness of the list is not.** A fourth module holding per-link
state that nobody adds to that closure stalls silently, in exactly the way those two comments describe.

**The proposal.** Name the `linkSettled` / `linkEnded` pair as one interface and let the composition root
register conformers, so conforming is joining.

### 6. Two modules, one queue-and-cooldown engine

**Worth exploring.** `Sources/FacetCore/FaceColourSync.swift` (246), `DeviceSettingsSync.swift` (301).

Both hold the same eight pieces of machinery: a queue deduplicated by key, `isSending`, a per-key cooldown,
`suppressed` counters, `isLinkSettled`, `wasCubeConnected`, a `linkSettled()` transition guard and a
`run()`/`step()` pump. They already share the constant, `DeviceSettingsSync.swift:86` reading
`static let cooldownSeconds = FaceColourSync.cooldownSeconds`. The number is one fact; the engine around it is
two.

**The proposal.** One queue module parameterised by key and payload. Each caller keeps only what it sends and
when it is stale.

### 7. A quarter of the Linux test exclusions are an unused import

**Strong, and the cheapest thing here. Acted on 2026-09-09, and the figure below was wrong.**
`Package.swift:41-92`.

> **Corrected when it was implemented.** This candidate claimed 162 tests for the cost of deleting an
> import. The real figure is **52 now and 110 after a migration**, because six of the ten files are
> `@MainActor` `XCTestCase` subclasses. `Package.swift` names that trap at the top of the section, and it is
> the worse one: such a file aborts the whole Linux run at load time rather than failing on its own, so
> un-excluding those six would have taken down all 873 tests that already pass there. Only four were safe.
> What follows is the finding as written; the correction is at the end of the section.

The list says these files need "AppKit, CoreBluetooth or a `FacetMac` type". **Ten of them need none of the
three**: each carries `@testable import FacetMac` and uses no type from it.

| Test file | lines / tests | Subject lives in |
| --- | --- | --- |
| `DeviceEventRecorderTests` | 528 / 35 | `FacetCore/DeviceEventRecorder` |
| `FaceColourSyncTests` | 350 / 22 | `FacetCore/FaceColourSync` |
| `TimeEntryRecorderTests` | 326 / 18 | `FacetCore/TimeEntryRecorder` |
| `DeviceSettingsSyncTests` | 293 / 18 | `FacetCore/DeviceSettingsSync` |
| `DeviceLoginRulesTests` | 190 / 25 | `FacetCore/DeviceLoginRules` |
| `LowBatteryWatchTests` | 174 / 10 | `FacetCore/LowBatteryWatch` |
| `DeviceReconnectRulesTests` | 142 / 17 | `FacetCore/DeviceReconnectRules` |
| `WriteDebounceTests` | 129 / 7 | `FacetCore/WriteDebounce` |
| `PortableSHA256Tests` | 98 / 5 | `FacetCore/PortableSHA256` |
| `CubeFirstReadingTests` | 76 / 5 | `FacetCore/CubeFirstReading` |

2,306 lines and 162 tests. Two details worth keeping:

- **In `DeviceEventRecorderTests` and `TimeEntryRecorderTests`, 854 lines and 53 tests of pure database
  behaviour, the only mention of a `FacetMac` type in either file is a comment.** Both cite
  `SettingsWindowController.startTiming` as prior art for an ordering, at `:437` and `:289`. The tests touch
  nothing from that class.
- **`PortableSHA256Tests` is excluded from the one platform it protects.** `PortableSHA256` is SHA-256
  written by hand because Linux has no CryptoKit, and it backs the PKCE challenge in Google sign-in. The
  suite guards CryptoKit correctly with `#if canImport(CryptoKit)`, and is then excluded on Linux at
  `Package.swift:74` by an import it does not use. Its own comment calls the vectors "the only thing standing
  between a one-digit typo in the round constants and a sign-in that fails on Linux and nowhere else". That
  reasoning was written when Linux could run no tests at all; it now runs 873.

`FaceColourSyncTests` also carries a dead `import AppKit` and uses no `NS` type.

Beyond those ten: `GoogleOAuthRulesTests` (282 / 21) has a real bind, an unconditional `import CryptoKit` used
to compute the expected PKCE challenge independently, fixable the same way `PortableSHA256Tests` already did
it. Five more files (910 lines, 56 tests) have one or two touch points with the rest portable, including
`QuitSequenceTests` (275 / 13), where only 4 of `QuitSequence`'s 186 lines touch `NSApplication`, and
`SettingsTabTests` (46 / 4), where exactly one assertion is not portable.

**The proposal.** Delete the unused import from ten files and take them off the list. Then make the list
falsifiable: a check that a file on it actually references a platform type, so it cannot drift again.
`scripts/check_interactive_checklists.sh` is the precedent for that kind of gate.

#### What was actually done, and the correction

Landed on 2026-09-09. The imports are gone from all ten files, and the compiler confirmed they were unused:
`swift build --build-tests` compiles every one of them without it, and `swift test` is green at 1,751 tests
(1,392 XCTest, 359 swift-testing, 0 failures). `FaceColourSyncTests` lost a dead `import AppKit` with it.

**Only four files could come off the exclusion list**, not ten:

| Off the list, 52 tests | Blocked by `@MainActor`, 110 tests |
| --- | --- |
| `DeviceLoginRulesTests` 25 | `DeviceEventRecorderTests` 35 |
| `DeviceReconnectRulesTests` 17 | `FaceColourSyncTests` 22 |
| `PortableSHA256Tests` 5 | `TimeEntryRecorderTests` 18 |
| `CubeFirstReadingTests` 5 | `DeviceSettingsSyncTests` 18 |
| | `LowBatteryWatchTests` 10, `WriteDebounceTests` 7 |

The six are `@MainActor` `XCTestCase` subclasses, and `Package.swift` already described what that does: it
"aborts the run at load time however well everything else behaves". Un-excluding them would have cost the
873 tests Linux already runs. They now sit on a restored `mainActorTests` list which names that blocker, so
`Package.swift` holds 44 exclusions in two lists that each say which of the two reasons they are, rather than
48 in one list that said only the first.

**The interaction between the two lists is the real finding, and it is worth more than the ten files.** A
suite on `platformBoundTests` was never a candidate for the swift-testing migration, because that list is
where things go that cannot run at all. So on 2026-09-07 the migration emptied its own queue and reported
the `@MainActor` list "gone because it emptied", while six migratable suites sat hidden on the other list.
An exclusion list has to say which of two reasons it is, or it silently absorbs the other.

**Verified on Linux, 2026-09-09, and the figure held.** `swift build --build-tests` compiled all four
first time and `swift test` ran **956 tests, 0 failures**, up 50 from 906. Not 52: `PortableSHA256Tests`
holds five methods but two sit inside its `#if canImport(CryptoKit)` guard, so three of them exist on this
platform. The other three suites ran their full 25, 17 and 5. Nothing failed, and nothing failed for a
reason about the platform.

**Then the 110 were mostly collected too, on the same day.** Four of the six `mainRunLoopTests` files
migrated to swift-testing and run on Linux, worth **93 tests**, taking it to **1,049**. The last two --
`LowBatteryWatchTests` and `WriteDebounceTests`, 17 tests -- turned out not to be blocked by the framework
at all: on Linux a `@MainActor` swift-testing test **does not run on the main thread**, so the
`RunLoop.main` timer that both subjects schedule never fires. That is measured in `docs/linux-port.md`
under *`@MainActor` is not the main thread*, and it is a better finding than the tests were worth: the
`mainActorTests` list had been named after a blocker that was only the shallower of two.

**The falsifiability gate was not built.** It would be a check that every file on `platformBoundTests`
actually references a platform type. It is still the right idea, and it is what would have caught this drift,
but a new gate is premature while the port is still moving.

### 8. `SettingsWindowController` owns far more than the window

**Strong, and the largest thing here.** `Sources/FacetMac/SettingsWindowController.swift`, 3,498 lines, 1,983
of them code, three declared types, no `// MARK:` anywhere.

Its own doc comment, line 4, says: "The Settings window: one tab per `SettingsTab`, each pane empty. Owns the
window and nothing else."

It also owns:

- **Every write of device and pairing state in the app.** All eight `DevicePairingRecorder` call sites in the
  repository are in this file (`:976`, `:1328`, `:1336`, `:1362`, `:1397`, `:1408`, `:1416`, `:2957`),
  including `recordQuit`, which `QuitSequence` reaches only through
  `settingsWindow.letGoOfTheDevice()` (`main.swift:230`).
- **Ten of the radio's eighteen callbacks**, in `adopt(_:)` (`:1179-1293`). The other eight are in
  `main.swift`. The method's comment explains why, so a paired app can follow its cube with no window open,
  which is correct reasoning for a module that is not a window controller.
- **The whole Google OAuth and calendar lifecycle**, 434 lines (`:1759-2192`), including network calls and
  Keychain writes.
- **`togglePause`** (`:2784`), which the status item and its dropdown both call.
- **The reconnect loop's two feedback inputs**, `noteOutcome` (`:1222`) and `noteDropped` (`:1291`). The loop's
  backoff therefore depends on a window having been constructed, joined by the single optional assignment at
  `main.swift:357`; a nil `reconnect` is a loop that quietly never retries.
- **The radio itself**, when nobody hands one over (`deviceRadio()`, `:1428`).

**Roughly 89% of the code is decisions, not drawing.** Genuine AppKit construction is the window chrome
(`:2962-3145`, 184 lines) plus `Layout`, `makePane` and eighteen `NSAlert` bodies: about 330 to 380 lines. The
other ~3,100 decide which store to ask, in what order to send and record, what to put back on a refusal, what
to log, and which of eleven change branches to take.

**There is no seam inside it.** 51 hard-wired concrete collaborators: `NSAlert()` 18 times,
`DevicePairingRecorder(` 8, `GoogleCalendarClient.*` 5, `NSApp.` 3, `GoogleTokenStore.*` 3, and one each of
`NSOpenPanel`, `NSSavePanel`, `NSWorkspace.shared`, `GoogleSignIn.run`, `BluetoothRadio(`. The substitution
points that exist (eleven injected optional stores, five closures, the pane callbacks) are not a place the
AppKit half could be replaced without editing here.

`SettingsWindowControllerTests` is 162 lines and 7 tests, all about tab-bar wiring. The behaviour is covered
by six scenario suites that each build the whole controller plus a real database plus AppKit, and every one is
excluded on Linux.

**The proposal.** Cut a seam between deciding and drawing: the write paths, the pairing recorder and the
Google lifecycle move below it into `FacetCore`, the AppKit chrome stays above, and a GTK window becomes a
second adapter rather than a rewrite.

**This one touches three `CLAUDE.md` rules** and is a direction to agree before it is a change to schedule:
the tab-width rule (a pane must keep its autoresizing frame and must not set
`translatesAutoresizingMaskIntoConstraints = false` on itself), the collapsible-group rule, and the Settings
window carve-out to the read-at-point-of-use rule.

### 9. Portable decisions parked behind AppKit types

**Strong.** `StatusItemTitle.swift:123-344`, `TimingView.swift:275`, `DevicePane.swift:151-175`,
`main.swift:279`.

`StatusItemTitle.make(...)` is ~195 lines deciding text, icon name, glyph name, lock glyph, formatted
duration, the spoken VoiceOver string, and which of five semantic colours each of three parts takes. Only the
colour representation is AppKit. And the file maps it straight back out again:

```swift
// StatusItemTitle.swift:335
private static func name(of colour: NSColor) -> String {
    switch colour {
    case .systemCyan: return "cyan"
    ...
```

The word is what `debug_log` and the scripted checks read, so the word was the answer all along. `NSColor` is
the only reason 530 lines and 52 tests cannot run on Linux.

**And the second answer already exists.** `FacetLinux/main.swift:99-107` reimplements a cruder version of the
same decision, `"Facet"` or `"<category> <elapsed>"`, with no colour, no glyph, no lock badge and no spoken
label. Two answers to one question on two platforms, which is the hazard `state-reference.md` exists to
prevent.

Three more of the same shape:

- **The cube pause glyph is decided twice**, identically, at `StatusItemTitle.swift:222` and
  `TimingView.swift:275`. `ManualTimerRules.symbolName` exists in `FacetCore` for the app's own clock; there
  is no equivalent for `cubePauseState`. The lock badge is the same, with two different symbol sets
  (`StatusItemTitle.swift:161`, `TimingView.swift:618`).
- **The seeded defaults live in an `NSView` subclass.** `DevicePane.Values.seeded`
  (`DevicePane.swift:151-175`) holds the 17 seeded defaults from `database/011_setting.sql`, and
  `main.swift:279` reaches into `DevicePane`, which is `final class DevicePane: NSView`, to build
  `DeviceSettingsSync.Stored`, which is a `FacetCore` module. A Linux launch that wants settings pushed to the
  cube cannot have them. `AppSettingsPane.Values.seeded` is the same shape.
- **`QuitSequence`** is 186 lines of which 4 touch `NSApplication`, and its 275-line, 13-test suite is
  excluded.

**The proposal.** Let each decision return its own vocabulary and convert at the point of drawing, exactly as
stage 1b of the FacetCore split already did for six files with `Colour`. Move the seeded defaults to the
schema's own side. `StatusItemTitle` was the one file on that stage's list that stayed behind, on the grounds
its colours are semantic AppKit ones; `name(of:)` is evidence the app already needs them as words too.

---

## The sequence worth doing them in

1. ~~**Candidate 7 first**, because it is about an hour and changes no production code.~~ **Done
   2026-09-09.** It changed no production code and cost about an hour as expected, but it is worth 52 tests
   rather than the 162 this review claimed, the other 110 needing a swift-testing migration first. It does
   include the only suite guarding the SHA-256 that Linux alone uses, and it corrects the exclusion list,
   which the port is being planned against. **Confirmed on Linux the same day**: 956 tests, 0 failures, and
   the migration that was "what is left of this one" then took four of its six files, for 93 more.
   **Linux runs 1,066 tests now**, the last 17 having arrived on 2026-09-09 as well. The run-loop question
   this listed as open was answered by neither option it named: not an injected `RunLoop` but a `fire()`
   extracted in each of the two, so their tests drive the timeout body instead of a run loop. What is
   genuinely left of this candidate is the falsifiability gate below, and nothing else.
2. ~~**Candidate 2 next**, because it is a day and it is diagnostic.~~ **Done 2026-09-09**, and it took an
   hour rather than a day. The leverage the split promised is collected: a second conformance, a file off the
   exclusion list, and 14 tests on two paths nothing drove. **The diagnostic came back negative** -- driving
   `DeviceReconnector` through those members was not awkward at all -- so it yields no evidence for candidate
   1, which is a different seam under a different concern and has to be argued on its own terms.
3. **Then candidate 1**, which is the one that pays: ~1,480 lines of untested portable sequencing, and a
   rewrite budgeted at 600 to 1,000 lines that becomes an adapter instead.

Candidate 8 is the same argument about the Settings window and is much the largest. It is worth agreeing as a
direction before it is scheduled as a change.

### The scripted suite is set aside until the Linux port is finished

**Superseded, and widened, on 2026-09-09.** This section first said the re-stamp waited on the end of this
review. The owner has since set the suite aside for the whole of the Linux port and will say when it comes
back, so the trigger is not a milestone in this document at all. **The rule lives in `CLAUDE.md`**, under
*The scripted suite is set aside until the Linux port is finished*, and that is the authority; what is below
is only why it costs nothing.

**`All tests pass` stays red until then, and that is the intended state rather than an outstanding job.**
Candidate 7 changed `Package.swift`, which `scripts/check_interactive_checklists.sh` watches whole, so the
stamp for run 173 at `079c3b8` is stale and the gate says so on every push. Clearing it needs
`Tests/Scripted/run.sh`, which needs a cube and a person for about twenty minutes. Nobody is to make it green
by other means: not the pathspec, not the stamp, not `LINUX_IS_ADVISORY`, not the workflow.

**Doing that now would be paying for it twice.** Every candidate still on this list lands in `Sources/`,
which is watched: 1, 2, 3, 4, 5, 6, 8 and 9 without exception, and candidate 1 moves roughly 1,480 lines of
it. So does the one piece of candidate 7 still open, since handing `WriteDebounce` and `LowBatteryWatch`
their `RunLoop` as a parameter is a change to `FacetCore`. Whatever run cleared the stamp today would be
stale again at the next commit, and the suite would have to be run once more at the end regardless. One run
at the end is one run; a run now is two.

**So this was `handover-mac.md` item 12 and was deleted deliberately rather than done**, against that
document's own rule that an item goes when it is finished. The exception is defensible because this is the
one outstanding job that announces itself: a stale stamp is not a note somebody has to remember, it is a red
check on every run, so nothing is lost by taking it off a list whose purpose is remembering. The trigger is
written here instead, where the thing it waits on lives.

**What that run will cover when it happens.** Two commits put `Package.swift` in the diff, `ec54dab` from the
Mac and `daf0e97` from the Linux box, plus whatever the candidates above add. One run clears all of it: a
stamp names a commit and the staleness check looks at the range, so waiting accumulates no debt. That is why
the suite can be set aside for the length of a port without anything being lost.

---

## What this review did not do

- **Nothing was changed.** No source file, no test, no manifest.
- **It did not run on hardware.** Every claim here is about the shape of the code, not about the cube. Nothing
  in it has been checked against a device, and candidate 1 in particular would need a full
  `Tests/Scripted/run.sh` before it could be believed.
- **It did not touch `linux-port.md`.** Several candidates bear directly on its to-do list, items 10 and 11
  especially, but cross-referencing them is a separate edit to a file both machines write to.
- **It re-checked the sub-agent counts rather than trusting them.** One was wrong in the safe direction: the
  CoreBluetooth line count came back as 42 and is 40 by hand, which does not change the argument.
