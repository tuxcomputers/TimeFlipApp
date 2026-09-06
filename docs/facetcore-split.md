# Splitting FacetCore out, on a Mac

[← Back to README](../README.md) · [Linux port status →](linux-port.md) · [The two systems →](systems-info.md)

**Instructions for work that cannot be done from the Linux machine.** There is no AppKit there, so
`FacetApp` cannot be compiled at all, and this change is mostly a conversation with the compiler. Read
[linux-port.md](linux-port.md) for why the split is wanted; this file is only how to do it.

**The whole method is: let the compiler enumerate the work.** Do not go through the sources making
things `package` in advance. Move the files, build, and fix exactly what it names. Guessing produces a
wider blast radius than the change needs and hides the one error that matters among four hundred that
do not.

## Before starting

```sh
swift build && swift test          # must be green, 1718 tests
git status                          # must be clean
git switch -c <your-branch>         # off feature/linuxPort
```

**Commit each stage separately.** Six stages follow and any of them can be reverted alone. A single
commit containing all of it is not reviewable and not bisectable.

**Budget a scripted run at the end.** `Sources/` moves wholesale, so
`Tests/Scripted/last-run-mac.md` goes stale and CI will refuse the branch until `Tests/Scripted/run.sh`
has been run with a cube. That is one run for the whole exercise, not one per stage.

---

## Stage 1: three decouplings, still one module

**Do these first, and keep them as three commits.** Each is worth having on its own, each is small, and
together they are what makes stage 2 mechanical rather than exploratory. Nothing here creates a target.

### 1a. `AppSettingsPane.Change` moves out of the pane

`AppSettingsRules` is decision logic and depends on a type nested inside a UI file -- the one genuine
layer leak in the codebase. Two references, `AppSettingsRules.swift:104` and `:141`.

Move the `Change` enum out of `AppSettingsPane.swift` into its own file, `AppSettingsChange.swift`, as a
top-level type. Keep the name if nothing collides. Update the pane and the two rules references.

### 1b. A colour type for the six `NSColor` files

These six import AppKit for `NSColor` and nothing else, and are data files rather than UI:

```
CategoryStore.swift   TimeEntryStore.swift   ColourStore.swift
FaceColourRules.swift DeviceFaceRules.swift  StatusItemTitle.swift
```

Give them a platform-free colour of their own -- four `Double` components is all any of them uses --
and convert to `NSColor` at the point the UI actually draws. Then drop `import AppKit` from all six.

**Check each one after converting**: the point is that the file no longer imports AppKit, so if one
still needs it, that file is not as portable as this list assumed and should stay behind rather than be
forced.

### 1c. `DeviceReconnector`'s radio becomes a protocol

`DeviceReconnector.swift:30` holds `private let radio: BluetoothRadio` and `:99` takes one as an
initialiser parameter. Those are the only two code references to `BluetoothRadio` outside the platform
half -- the other nineteen mentions are doc comments.

Declare a protocol with just the members `DeviceReconnector` uses, have `BluetoothRadio` conform, and
depend on the protocol. It also makes the reconnector testable without a radio, which it currently is
not.

**After each of 1a, 1b, 1c:** `swift build && swift test`. All three are macOS-only edits and none
should change behaviour.

---

## Stage 2: create the target and move the files

```sh
mkdir -p Sources/FacetCore
git mv Sources/FacetApp/<file>.swift Sources/FacetCore/     # for each file below
```

Add to `Package.swift`, before the `FacetApp` target:

```swift
.target(
    name: "FacetCore",
    path: "Sources/FacetCore",
    resources: [.process("Resources")]        // see stage 4 -- the DDL has to come too
),
```

and give `FacetApp` `dependencies: ["FacetCore"]`.

`main.swift` stays in `FacetApp`: an executable target needs it, and a library target may not have one.

### The files that move

Computed from imports, after stage 1 frees the six colour files. **83 files.** Treat it as a starting
point rather than gospel -- if the compiler says one of these needs AppKit, it stays behind, and that is
a finding worth writing into `linux-port.md` rather than working around.

```
AppSettingsRules.swift              BatteryRules.swift                  CalendarSync.swift
CategoryCreateRules.swift           CategoryEditRules.swift             CategoryLastUsedText.swift
CategoryRenameRules.swift           CategoryStore.swift                 CollapsibleSection.swift
ColourStore.swift                   CubeFirstReading.swift              CubeLock.swift
CubeLockRules.swift                 CubeNotFoundOffer.swift             CubeStates.swift
DailyLimitEnforcement.swift         DailyLimitWatch.swift               DatabaseBootstrap.swift
DatabaseConnection.swift            DatabaseEnvironment.swift           DayTotal.swift
DayWindow.swift                     DebugLog.swift                      DebugTraceFile.swift
DebugTraceRules.swift               DeveloperConfigFile.swift           DeviceCommandRules.swift
DeviceEventRecorder.swift           DeviceEventRules.swift              DeviceFaceRules.swift
DeviceHistoryRules.swift            DeviceInfoRules.swift               DeviceLoginRules.swift
DeviceNameRules.swift               DevicePINRules.swift                DevicePINSource.swift
DevicePINStore.swift                DevicePairingRecorder.swift         DevicePairingRules.swift
DeviceReconnectRules.swift          DeviceReconnector.swift             DeviceScanRules.swift
DeviceSettingsSync.swift            DeviceSystemStateRules.swift        DoubleTapRules.swift
DurationFormat.swift                FaceColourRules.swift               FaceColourSync.swift
FaceStore.swift                     FacesTabRules.swift                 ForcedPause.swift
ForcedPauseWatch.swift              GoogleAccountRules.swift            GoogleCalendarClient.swift
GoogleCalendarRules.swift           GoogleEventClient.swift             GoogleEventRules.swift
GoogleOAuthRules.swift              GoogleTokenStore.swift              HistoryIngestor.swift
HistoryTimer.swift                  IconStore.swift                     InstanceLock.swift
LowBatteryWatch.swift               ManualTimerRules.swift              PauseMenuRules.swift
ReportCalendarGrid.swift            ReportCalendarMetrics.swift         ReportEntryText.swift
ReportRangeRules.swift              ReportSortRules.swift               SettingStore.swift
SettingsMetrics.swift               SettingsTab.swift                   StatusItemClickRouter.swift
StatusItemTitle.swift               StepperHoldRules.swift              TimeEntryRecorder.swift
TimeEntryRules.swift                TimeEntryStore.swift                TimezoneStore.swift
TimingReadout.swift                 WriteDebounce.swift
```

**`StatusItemTitle` is on that list and does not move.** Its colours are semantic AppKit ones and have to
resolve as they draw; `linux-port.md` has the detail. The list was computed from import lines, which say
what a file needed once -- `CollapsibleSection` and `FaceColourSync` were carrying an `import AppKit`
neither still used.

What actually moved, on 2026-09-06, was **86 files**: those 83, minus `StatusItemTitle`, plus `Colour`,
`AppSettingsChange` and `CubeRadio` from stage 1, plus `GoogleCredentials`, which had to come out of
`GoogleOAuthClient.swift` for the same reason `AppSettingsPane.Change` came out of the pane.

The 35 that stay are the platform layer: the panes and views, `BluetoothRadio`, `DeviceLogin`,
`BLETrace`, `TimeFlipUUIDs`, `MenuBarController`, `MainMenu`, `ActivityIcon`, `GoogleOAuthClient`,
`QuitSequence`, `StatusItemTitle`, `ColourDrawing`, and `main.swift`.

---

## Stage 3: the access-level loop

This is the bulk of the work and it is mechanical. **Do not pre-emptively edit anything.**

**The grep this file first carried matched nothing, and here is the one that works.** An `internal`
declaration in another module is not visible-and-refused, it is not visible at all, so the compiler says
`cannot find` rather than `is internal`:

```sh
swift build 2>&1 \
  | grep -oE "cannot find (type )?'[A-Za-z_][A-Za-z0-9_]*'" \
  | grep -oE "'[^']*'" | tr -d "'" | sort -u
```

Fix what it names, rebuild, repeat until the list is empty. **Done 2026-09-07: 589 `package`
declarations, 152 types and 437 members** (`linux-port.md` has the comparison against the estimate).
The first build names 94 types; widening those exposes the next layer, for about a dozen rounds.

**The grep above only starts it.** Once the types are visible the errors become
`'x' is inaccessible due to 'internal' protection level`, and the useful part is not the error but the
note beside it:

```sh
swift build 2>&1 | grep -E "^/.*note: '.*' declared here"
```

That carries the declaration's own file and line, which is everything a widening pass needs. Matching on
member names instead is ambiguous, 15 of 70 in the run that tried it; the note is not ambiguous at all.

### Use `package`, not `public`

Both targets live in the same package, so `package` is the correct level and is what this needs:

```swift
package struct CategoryRecord { … }
package func integer(_ name: String, field: String) -> Int?
```

`public` would also compile, but it declares these to be API for anybody importing the package, which
they are not, and it drags in questions about API stability that do not apply. `package` says exactly
what is true: visible across this package's targets, invisible outside it.

**A `package` type still needs `package init`.** Swift does not widen a memberwise initialiser
automatically, and this is the single most common error in this stage.

### Two things that reduce the work

- **`@testable import` reaches `internal`**, so the test target usually needs nothing widened. Do not
  make something `package` because a *test* wanted it -- that is what `@testable` is for.
- **A type only the core uses stays `internal`.** The compiler will not ask for it. If you find yourself
  widening something the error list never mentioned, stop.

---

## Stage 4: resources, and the trap in them

**`Bundle.module` is per-target.** `DatabaseBootstrap` moves to `FacetCore` and calls
`Bundle.module.url(forResource: "001_event_type", …)`, which after the move resolves to *FacetCore's*
bundle. If the DDL stays behind, that call returns nil and the fallback path is all that is left.

So `Sources/FacetApp/Resources/Database` -- the symlink to the real `database/` at the repository root --
moves to `Sources/FacetCore/Resources/Database`, and its target is `../../../database` from there too,
so the link text does not change. Verify it resolves after moving:

```sh
readlink -f Sources/FacetCore/Resources/Database    # must print <repo>/database
```

Carry the two `exclude:` entries for `CLAUDE.md` and `ER-diagram.md` across to the `FacetCore` target.

**The icons stay with `FacetApp`.** `ActivityIcon` is AppKit and does not move, so `Resources/Icons` and
`AppIcon.icns` stay where they are. `FacetApp` keeps its own `resources:` declaration for them.

**`google-client.json` does move**, which this file did not anticipate. `GoogleCredentials.builtIn`
reads it through `Bundle.module` and that type belongs in the core, so the file goes to
`Sources/FacetCore/Resources/`. It is gitignored rather than tracked, so it is moved with `mv` and not
`git mv`, and `.gitignore` and `scripts/generate-credentials.sh` both name the path.

---

## Stage 5: the test target

`Tests/FacetAppTests` currently does `@testable import FacetApp` in 99 files. After the split, a test
of a moved type needs `@testable import FacetCore` instead, and a few will need both.

The cheapest correct approach is to leave the target as one and add the second import where the compiler
asks for it:

```sh
swift build --build-tests 2>&1 | grep "cannot find" | sort -u
```

Splitting the tests into `FacetCoreTests` and `FacetAppTests` is tidier and is what eventually lets the
Linux build run the core's tests without AppKit -- but it is a second change, not part of this one, and
it interacts with the swift-testing migration (`linux-port.md`, to-do item 6). Do not do both at once.

---

## Stage 6: verifying it

```sh
swift build                 # both targets
swift test                  # 1718 tests, all green
scripts/run.sh              # the app actually launches and pairs
```

Then the scripted suite, which is the only thing that says it works:

```sh
Tests/Scripted/run.sh       # needs a cube and a person to turn it
```

Commit the stamp it writes. CI reads `Tests/Scripted/last-run-mac.md` and will refuse the branch without it.

### What good looks like

- `swift build` clean, no warnings introduced
- 1718 tests green, none skipped
- 32 scripted checks passed, 0 failed, 0 short
- `git diff --stat` dominated by renames, with real edits confined to `Package.swift`, the access
  modifiers, and the three stage-1 decouplings

### If it goes wrong

Each stage is its own commit, so `git revert` the stage rather than unpicking it. The stage most likely
to be abandoned is 3, and abandoning it is a legitimate outcome: `#if canImport(AppKit)` around the 33
platform files achieves a Linux build with no access changes at all, and `linux-port.md` records it as
the alternative route. Nothing downstream requires two targets specifically -- what is needed is that
the portable half can be compiled without AppKit.

---

## When it is done

Update [linux-port.md](linux-port.md) in the same change: to-do item 2, the access-level finding, and
anything the compiler contradicted about which files were portable. That file is the record of what is
known, and a split that lands without it moving is a split somebody has to re-derive.
