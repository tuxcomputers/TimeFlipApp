# TODO: Removing Developer Mode

[← Back to README](../README.md)

`DeveloperMode` (`Sources/TimeFlipApp/DeveloperConfigStore.swift`) actually bundles two
independent features under one switch. Decide separately what happens to each before deleting
anything — removing one doesn't require removing the other.

1. **Dev config file** — when `DeveloperMode.isEnabled` is `true`, Google API credentials and the
   device PIN are read from/written to `config.json` (in the app's Application Support folder)
   instead of Keychain/UserDefaults. This is the part that's actually dev-only and should
   disappear before a public release — it lets a `config.json` on a dev machine silently override
   real user credentials.
2. **Debug console logging** — `DeveloperMode.debugPrint(_ tag:_:)` and the `DebugTag` registry
   (the `HH:mm:ss [Tag]` convention documented in the root `CLAUDE.md`). This is just a
   print-gating switch; it may be worth keeping as a permanent, always-`false`-by-default debug
   toggle rather than deleting it outright. Make an explicit call on this before touching it.
   Printing is now also gated on the `debug` setting's `enabled` field (loaded once at launch
   into `DeveloperMode.isDebugSettingEnabled`), so a user can turn terminal logging off/on
   themselves by editing that DB row directly, without a rebuild. Every message is now *also*
   persisted into the `debug_log` table (`database/010_debug_log.sql`) under the same gate, so a
   failed test session can be queried from the database afterward instead of needing a captured
   terminal transcript.
3. **Planned: debug log-to-file for end users** (§3 below) — a separate, user-facing feature
   that reuses the same debug messages but ALSO writes them to a file, so a non-technical user
   can enable it and send the file back for support. Not implemented yet; only the DB setting
   seed and the terminal-side `enabled` gate above exist so far — `to_file` doesn't do anything.

This list was generated 2026-07-17 by grepping for every `DeveloperMode` / `isDeveloperConfigLoaded`
/ `DeveloperConfigStore` / `DeveloperConfigPayload` reference in `Sources/`. Line numbers will
drift as the code changes — treat them as a starting point, not gospel.

## 1. Dev config file (`config.json` credential source)

- **`Sources/TimeFlipApp/DeveloperConfigStore.swift`**
  - `DeveloperConfigPayload` struct (Google client ID/secret + device PIN, `Codable`)
  - `DeveloperConfigStoring` protocol
  - `DeveloperConfigStore` class (`load()`/`save()` against `config.json`)
  - `DeveloperModeGoogleAuthStateStore` (in-memory OAuth token stand-in used only while dev mode
    is active — re-authenticates every launch instead of touching Keychain)
  - If the debug-print half (§2) is kept, only delete the `DeveloperConfigPayload` /
    `DeveloperConfigStoring` / `DeveloperConfigStore` / `DeveloperModeGoogleAuthStateStore`
    declarations here, not the whole file.

- **`Sources/TimeFlipApp/AppState.swift`**
  - `developerConfigStore` property + init parameter (`AppState.swift:10,72,77`)
  - `isDeveloperConfigLoaded` published property (`AppState.swift:48`)
  - The entire `// MARK: - Developer mode` section (`AppState.swift:112-137`): `isDeveloperConfigActive`,
    `applyDeveloperConfig()`, `persistDeveloperConfig()`
  - `if DeveloperMode.isEnabled { applyDeveloperConfig() }` in `init` (`AppState.swift:106`)
  - `guard !isDeveloperConfigActive else { return }` in `loadDevicePassword()` (`AppState.swift:140`)
  - `guard !hasLoadedClientSecret, !isDeveloperConfigActive else { return }` in
    `loadClientSecretOnce()` (`AppState.swift:148`)
  - `if isDeveloperConfigActive { persistDeveloperConfig() }` branches in `persistPreferences()`,
    `persistGoogleClientSecret(_:)`, and `persistDevicePassword(_:)` (`AppState.swift:442, 459, 473`)

- **`Sources/TimeFlipApp/ApplicationDelegate.swift`**
  - `authManager`'s `stateStore:` ternary — picks `DeveloperModeGoogleAuthStateStore()` vs
    `KeychainAuthStateStore()` (`ApplicationDelegate.swift:10-13`)
  - `if confirmed, !(self?.appState.isDeveloperConfigLoaded ?? false)` guard before clearing the
    Keychain password on a confirmed device reset (`ApplicationDelegate.swift:171`)
  - `if !self.appState.isDeveloperConfigLoaded` guard before saving a rotated device password to
    Keychain (`ApplicationDelegate.swift:349`)

**After removing this half:** credentials always go through Keychain/UserDefaults; there's no
`config.json` codepath left; delete `config.json` handling from any dev setup docs/scripts too.

## 2. Debug console logging (`DeveloperMode.isEnabled` / `debugPrint`)

- **`Sources/TimeFlipApp/DeveloperConfigStore.swift`**: `isEnabled` flag, `isDebugSettingEnabled`
  var, `logSink` closure var, `DebugTag` enum, `debugTimeFormatter`, `debugPrint(_:_:)` itself
- **`Sources/TimeFlipApp/AppDataStore.swift`**: `loadDebugEnabled()` (reads the `debug` setting's
  `enabled` field) and `recordDebugLog(tag:message:)` (writes to `debug_log`)
- **`Sources/TimeFlipApp/ApplicationDelegate.swift`**: the
  `DeveloperMode.isDebugSettingEnabled = dataStore.loadDebugEnabled()` assignment and the
  `DeveloperMode.logSink = { ... }` wiring, both at the top of `applicationDidFinishLaunching`
- **`database/010_debug_log.sql`**: the `debug_log` table itself — if debug logging is removed
  entirely, drop this table/migration file too, not just the Swift call sites
- **`CLAUDE.md`** (root): the entire "Debug print messages" convention section — describes this
  exact mechanism and would need to be removed or rewritten
- Every call site (all gated through `debugPrint`, so removal is mechanical once the decision is
  made to actually rip out logging rather than just leave `isEnabled = false` permanently):
  - `Sources/TimeFlipApp/AppDataStore.swift` — `verifyMaxKnownEventNumberConsistency()`
    (`.devCheck` tag; note this function's *entire body* is also gated on `DeveloperMode.isEnabled`
    at the top, not just its prints, at `AppDataStore.swift:256`)
  - `Sources/TimeFlipApp/HistoryIngestor.swift` — history-fetch-triggered message (`.history` tag,
    `HistoryIngestor.swift:79`)
  - `Sources/TimeFlipApp/MenuBarController.swift` — low-battery latch message (`.battery` tag,
    `MenuBarController.swift:140`)
  - `Sources/TimeFlipApp/TimeFlipBLEDevice.swift` — by far the most call sites (`.timeFlip` tag):
    operation-timeout messages, password write/login flow, password rotation/reset confirmation,
    and lock trigger/verification messages
  - `Sources/TimeFlipApp/ApplicationDelegate.swift` — lock icon optimistic-update message
    (`.timeFlip` tag, `ApplicationDelegate.swift:515`)

**If keeping debug logging:** nothing to do — it's already isolated behind `DeveloperMode.debugPrint`
and gated by `isEnabled`, so leaving `isEnabled = true` in dev builds and flipping it to `false` for
release is a one-line change, not a removal.

**If removing debug logging entirely:** delete every call site above, then the `DebugTag` enum,
`debugPrint`, `debugTimeFormatter`, and the CLAUDE.md convention section. Double-check no call
site was missed with `grep -rn "DeveloperMode" Sources/`.

## 3. Planned: debug log-to-file for end users

**Status: not implemented.** The `debug` setting's `enabled` field already gates two real
destinations today — terminal output (§2 above) and the `debug_log` table (§2 above, added in
`database/010_debug_log.sql`) — so a failed test session can already be analyzed by querying the
database directly, without a terminal transcript. Its `to_file` field is seeded but does nothing
yet; everything below is the intended design for whoever builds the file-writing side, not
current behavior.

**Motivation:** the database route (§2) works well when someone with DB access (e.g. a developer)
can query the user's `appdata.sqlite` afterward. `to_file` is for the case where that's not
practical — a non-technical user who needs to send something back rather than have their database
queried directly.

**How it relates to existing logging:** all three destinations are independent and can be active
at once — none of them replace another:
- `debug.enabled` → gates console/terminal output *and* the `debug_log` table, as implemented
  today (`DeveloperMode.isDebugSettingEnabled` + `DeveloperMode.logSink`, alongside the
  `DeveloperMode.isEnabled` compile flag).
- `debug.to_file` (planned) → the same debug messages additionally written to a file. When
  implemented, this most likely means `DeveloperMode.debugPrint` grows a third output path
  (file) gated on `to_file` specifically, so a user can have file logging on independent of
  whatever `enabled`/terminal/`debug_log` output is doing.

**The `debug` setting** (`{"enabled": true, "to_file": false, "directory": "~/Documents/TimeFlip"}`):
- `enabled` — **implemented**: gates terminal debug printing (§2 above).
- `to_file` — **not implemented**: whether debug messages are also written to a log file.
  Defaulted to `false` since the file-writing side doesn't exist yet — flipping it on today does
  nothing.
- `directory` — folder the log file will be written into once `to_file` is built. Defaults to
  `~/Documents/TimeFlip`; the `~` needs expanding to the real home directory at load time (e.g.
  `NSString(string:).expandingTildeInPath` or `FileManager.default.homeDirectoryForCurrentUser`),
  it isn't stored pre-expanded since a literal path would be wrong on another user's machine.
  A future Preferences UI will let the user override this via a folder-selection dialog
  (`NSOpenPanel` with `canChooseDirectories = true`); until then it's fixed at the seeded default.

**Log filename format (not stored in the DB — intentionally not user-configurable):**
`log-yyyy-MM-dd-HH.mm.ss` (e.g. `log-2026-07-17-18.53.42`), using standard `DateFormatter`
tokens — 24-hour hour (`HH`), to match the same local-time convention as the in-app debug print
timestamps (see CLAUDE.md). The timestamp is the moment the app *starts*, not the moment each
line is written — one log file per app session/launch, not one per day or per line. When
implemented, this format string should live as a single named constant on whatever type ends up
doing the file writing (e.g. `DebugFileLogger.filenameDateFormat`), specifically so it stays easy
to change in one place later, per the original request.

**Restart-required behavior:** like the other DB-only settings (`pause_on_lock`,
`low_battery_level`), toggling either `debug.enabled` or (once built) `debug.to_file` only takes
effect on the next app launch — both are read once at startup (`applicationDidFinishLaunching`
for `enabled`; the log file would be opened once at startup too, with a filename fixed for that
whole session). Once a Preferences UI exists for either, it must explicitly tell the user that
flipping it won't take effect until they restart the app — don't let them assume it's already
in effect.

**Left for the actual implementation to figure out:**
- Whether `directory` gets created if it doesn't exist yet (`~/Documents/TimeFlip` won't exist on
  a fresh machine).
- What happens if the directory is unwritable (permissions, external volume unmounted, etc.) —
  probably fall back to terminal-only output rather than crashing or silently dropping logs.
- Log rotation / cleanup of old log files, if any — not specified yet.

## Verifying nothing was missed

```
grep -rn "DeveloperMode\|isDeveloperConfigLoaded\|DeveloperConfigStore\|DeveloperConfigPayload" Sources/
```

should return nothing once both halves above are fully removed.
