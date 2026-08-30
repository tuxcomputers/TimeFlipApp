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

## The `debug` setting row: seeded, and read by nothing

`011_setting.sql` seeds `debug` = `{"enabled":true,"to_file":false,"directory":"~/Documents/Facet"}`. **No code reads
any of the three fields.** One gate is enough while the only audience is a developer with a terminal open, and a
second gate that nothing consults is worse than none.

It is the obvious home for the decision in §3 above. The intended design, for whoever builds it:

- **`enabled`** — whether messages are gathered at all, so a user can turn logging on without a rebuild. This is what
  would let a released build keep `DebugLog` and still be quiet by default.
- **`to_file`** — the same messages also written to a log file, for the case the database route does not serve: a
  non-technical user who needs to *send* something back rather than have their database queried. The three
  destinations (terminal, `debug_log`, file) are independent and none replaces another.
- **`directory`** — where that file goes. Defaults to `~/Documents/Facet`; the `~` needs expanding at load time
  rather than being stored pre-expanded, since a literal path is wrong on another machine. A folder picker
  (`NSOpenPanel`, `canChooseDirectories = true`) would come with the Settings row.

**Filename format, deliberately not user-configurable:** `log-yyyy-MM-dd-HH.mm.ss`, 24-hour, matching the local-time
convention of the console prefix. The timestamp is when the app *started*, so it is one file per launch rather than
one per day or per line. It should live as a single named constant on whatever does the writing, so it stays easy to
change in one place.

**Restart-required behaviour:** both fields would be read once at startup (the log file's name is fixed for the
session), so a Settings row for either has to say plainly that flipping it takes effect on the next launch, rather
than letting somebody assume it is already in force.

**Left for the implementation:** whether `directory` is created if absent (`~/Documents/Facet` does not exist on a
fresh machine), what happens when it is unwritable (probably fall back to terminal-only rather than crashing or
silently dropping), and log rotation, which is unspecified.

Note that `debug_log` already has no retention or cleanup of its own: `debug.sqlite` grows for as long as the app is
built with the flag on. `Tests/Scripted/run.sh` deletes it on a clean rebuild, and the app recreates it next launch.

## Verifying nothing was missed

```
grep -rn "DeveloperMode" Sources/
```

should return the five call sites above, plus `DeveloperMode.swift` itself and the comment in `DebugLog.swift`.
