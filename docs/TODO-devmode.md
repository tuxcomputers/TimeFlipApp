# TODO: the developer-mode gate, before release

[← Back to README](../README.md)

**`DeveloperMode.isDeveloperMode` is a hardcoded `true`** (`Sources/FacetApp/DeveloperMode.swift`). That is fine while
the app is unreleased and must not ship that way. This file is the inventory of everything that hangs off it, so the
decision about each is taken deliberately rather than discovered by a user.

It is one flag, compile-time, and nothing else: there is no `config.json` credential path, no `logSink`, no
`isDebugSettingEnabled`. The previous app bundled several independent features under one switch and this rebuild
deliberately did not; what follows is short because of that.

## What the flag gates today

Five call sites, and each wants a different answer.

### 1. The device PIN (`DeveloperMode.devicePIN`)

`nil` in any build without the flag, `"123456"` with it, and it has two jobs which are the same value on purpose:
what a cube is **set to** once it has let the app in (`DeviceLoginRules.rotation`), and what **stands in as the stored
PIN** when `config.json` names none.

**`nil` is not unfinished, it is the safe answer**, and the reason is written out in `DeveloperMode.swift`: a release
build would want six random digits, which is only safe once there is somewhere durable to keep them. Setting a PIN the
app cannot write down would lock the cube out of every app including this one, so until such a store exists a
non-developer build leaves the cube on whatever PIN let it in.

**Decision needed:** whether a release build gets a credential store (the archive used the Keychain) and starts
rotating PINs, or ships never setting one. Flipping the flag alone already does the second, correctly.

### 2. `config.json` (`DeveloperConfigFile`)

`DeveloperConfigFile.standard` returns `nil` without the flag, so a release build has no `config.json` at all rather
than a path nothing writes to. It holds exactly one key, `PIN`, and merges rather than re-encoding the whole file, so
a developer's existing `client_id`/`client_secret` survive a write.

**Nothing to remove**, and this is the narrow exception `CLAUDE.md` asks to be named at the point it is taken: the PIN
is a credential, a database is copied around and rebuilt from the DDL by the test suite, and a cube does not know
which database is in play — so a PIN kept in one is a PIN a database swap loses.

### 3. The debug trace (`DebugLog`, `main.swift`)

`debugLog` is `nil` without the flag, so a release build constructs no logger at all rather than one that returns
early, opens no `debug.sqlite`, and writes no `debug_log` rows. Every call site is `debugLog?.record(...)`, so nothing
needs an `if` around it and removal is not required to ship.

**This is the one to think hardest about**, because the scripted suite is built entirely on it: every check is "press
by name, then poll for the row" (`Tests/Methods.md`). Turning it off in a release build means the released build is
not the build the suite can drive.

**Decision needed:** almost certainly keep it, gated on something a user can turn on — which is what the seeded
`debug` setting row was for. See below.

### 4. The database badge (`main.swift`)

The `TEST` / `PROD` / `DB?` tag at the left of the menu bar item is drawn only with the flag on. A released app only
ever has the real database, so a permanent `PROD` tag would occupy the menu bar to answer something nobody asked.

**Nothing to decide.** Flipping the flag does the right thing.

### 5. The history-fetch floor (`HistoryTimer.interval`)

`fetch_history_interval_seconds` is clamped to a floor of **1 second** with the flag and **60 seconds** without it
(the maximum is 3600 either way). The seeded default of 10 is below the production floor deliberately: it is a
developer's value, and a release build silently raises it to a minute.

**Nothing to decide**, but worth knowing that flipping the flag changes real behaviour here rather than only hiding
something.

## The `debug` setting row: on the App tab, and still not read by the logger

`011_setting.sql` seeds `debug` = `{"enabled":false,"directory":"~/Library/Application Support/Facet"}`, and the App
tab's **Debug** section shows both fields: a switch and the folder, with a Choose button on the folder
(`AppSettingsPane`, `DebugTraceRules`). The section is folded when the tab is built, being the one group on that tab
nobody opens it to change.

**`directory` is honoured.** `main.swift` reads it where the trace database is opened, so the folder decides where
`debug.sqlite` goes; a folder that cannot be written falls back to the one beside `appdata.sqlite` and says so on
stderr. It is read at launch and the file stays open until quit, so a folder chosen on the tab applies from the next
launch, which the row says out loud.

**Finding the file is a button, not a path.** The section's Trace file row reveals `debug.sqlite` in the Finder and
saves a copy of it (`DebugLog.copy(to:)`, a `VACUUM INTO` so the copy is consistent while the app is still writing).
That is why the seeded folder can stay in Application Support: somewhere familiar like `~/Documents` would put a
continuously written database inside an iCloud sync root, which is the standard way to get a corrupted sqlite file,
and it would have bought only findability -- which the buttons give for nothing.

**`enabled` is stored and read by nothing.** The gate is still the compile-time flag, which is §3 above and the
decision left to take:

- **`enabled`** — whether messages are gathered at all, so a user can turn logging on without a rebuild. This is what
  would let a released build keep `DebugLog` and still be quiet by default.
- Gating `DebugLog`'s construction on it is the whole of the work, and it is where the seeded `false` bites: **the
  scripted suite is built on `debug_log` rows**, so the same change has to turn the row on before the suite launches
  the app (`Tests/Scripted/lib.sh`), or every check goes dark at once.
- **A restart is part of it.** `DebugLog` is constructed once, at launch, and every call site is
  `debugLog?.record(...)` -- so an app built without a logger costs nothing at all, which is the property worth
  keeping. Reading the row per message instead would put a `SELECT` and a string interpolation on every BLE packet in
  the common case where logging is off. So turning it on takes effect at the next launch, and the Debug section has
  to say so.

**`to_file` is gone** (2026-09-03). It was the same messages written to a plain log file, for a non-technical user
who needs to *send* something back -- which is exactly what `debug.sqlite` is, for support and for the scripted suite
alike. Nothing is lost by dropping it, and a second destination would have been a second thing to keep in step.

Note that `debug_log` already has no retention or cleanup of its own: `debug.sqlite` grows for as long as the app is
built with the flag on. `Tests/Scripted/run.sh` deletes it on a clean rebuild, and the app recreates it next launch.

## Verifying nothing was missed

```
grep -rn "DeveloperMode" Sources/
```

should return the five call sites above, plus `DeveloperMode.swift` itself and the comment in `DebugLog.swift`.
