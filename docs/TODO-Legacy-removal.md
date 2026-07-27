# Legacy storage removal

**Goal: every piece of persisted state lives in the SQLite database or the Keychain, and nowhere
else.**

This lists everything that was persisted outside those two at the branch's fork point —
`00a9388`, the merge of `feature/testAutomation` into `main` — so the list is fixed and progress
against it is measurable. A box is ticked only when the legacy copy is **gone**, not when the
database merely has somewhere to put it.

**7 of 13 done.** All four pairing fields and all three Google fields have moved. What remains is
the four per-facet mappings, each still with a live production reader, and the two developer-mode
files, which are intentional escape hatches rather than oversights. `PreferencesPayload` is now
nothing but `facetMappings` — the `timeflip.preferences` key disappears with them. Two dead paths
that needed no migration have also been cleared: see
[Legacy paths already removed](#legacy-paths-already-removed).

## UserDefaults — the `timeflip.preferences` blob

One `UserDefaults` key holds a JSON-encoded `PreferencesPayload`
(`Sources/TimeFlipApp/PreferencesStore.swift`). It is the only `UserDefaults` key the app uses.
Every field below is a member of that one blob, so the key itself only disappears once all of them
have moved.

### Per-facet mappings (`facetMappings: [FacetMappingRecord]`)

- [ ] **Facet name** — free text per facet, `""` meaning unassigned.
      *DB home:* `face.category_id` → `category.category_name`, which already exists and is what
      the menu bar displays. The Faces tab, which still shows and edits it, is now the **only**
      reader — `HistoryIngestor` no longer derives a name from it (see
      [Legacy paths already removed](#legacy-paths-already-removed)). Removing that last reader
      needs the Faces tab's category-assignment UI (see
      [TODO-features-under-development.md](TODO-features-under-development.md) § Faces).
- [ ] **Facet icon** — asset name (`ic_meeting`), `""` for none.
      *DB home:* `category.icon_id`, already live for the menu bar and editable on the Categories
      tab. Only the Faces tab still reads the blob field, so the same blocker as the name.
- [ ] **Facet colour** — `ColorComponents` (r/g/b/a).
      *DB home:* `category.colour_id`, which exists and is editable, but the **device's own LED
      colour is still driven from the blob** (`ApplicationDelegate` → `setFacetColor`, BLE `0x11`).
      The only one of the four whose remaining reader is outside the UI entirely, so it needs the
      device write repointed at the category's colour, not just a tab reworked.
- [ ] **Facet daily limit** (`limitMinutes`) — whole minutes, `0` = none.
      *DB home:* `category.daily_limit`, which exists and is editable but has no reader. The menu
      bar's over-limit indicator still takes its value from the blob.

### Google integration

- [x] **`googleCalendarID`** — the calendar events sync into. *Done — the `calendar_id` key on the
      existing `google_account` setting row.*
- [x] **`googleCalendarName`** — display name for the above, cached to avoid a lookup. *Done —
      `calendar_name` on the same row.*
- [x] **`googleClientID`** — OAuth client id. Not a secret (it appears in every OAuth URL), which
      is why it is not in the Keychain alongside the client secret. *Done — `client_id` on the
      same row.* Developer mode's `config.json` still overrides it at launch, unchanged.

  All three joined `google_account` rather than taking a row of their own. Sign-out resets only
  that row's `name` and `email`, so configuration sharing the row is not collateral damage.

### Pairing state

- [x] **`isPaired`** — whether a device is currently paired. *Done.* The field only ever existed
      as a backward-compatibility fallback for `wantsPairing` (and `persistPreferences` wrote it
      *from* `wantsPairing`, so the two always held the same value). Removed along with
      `wantsPairing` below; the runtime `isPaired` always starts `false` and is established by
      actually connecting.
- [x] **`wantsPairing`** — whether the user has asked to be paired, distinct from currently being
      paired. *Done — the `wants` key on the new `paired_device` setting row.* Deliberately not
      folded into `paired`: that flag is cleared on every transient disconnect, so the two
      together would lose the intent across a quit while the device is out of range, and the app
      would come back up never attempting to reconnect.
- [x] **`pairedDeviceName`** — remembered device name, shown while disconnected. *Done — the
      `name` key on `paired_device`.* The "Not paired" placeholder is a display default and is
      stored as absent rather than as that string.
- [x] **`pairedDeviceUUID`** — CoreBluetooth peripheral identifier, used to reconnect to the same
      device rather than rediscovering. *Done — the `uuid` key on `paired_device`.*

  All three share a row because they share a lifetime: they change only when the user pairs or
  forgets a device. `AppState` takes them through its initialiser at launch and
  `ApplicationDelegate` writes every change back.

## Application Support files

Both live in `~/Library/Application Support/TimeFlip/`, alongside the database.

- [ ] **`config.json`** (`DeveloperConfigStore`) — developer mode only. Holds `client_id`,
      `client_secret` and `PIN` (the device password), deliberately bypassing Keychain and
      UserDefaults so a dev can symlink the file to a checked-out credentials file.
      Two of the three are secrets whose non-developer home is already the Keychain. This one is
      an intentional developer-mode escape hatch rather than an oversight, so removing it means
      removing developer mode's file backing, not migrating data.
- [ ] **`config.auth.json`** (`DeveloperModeGoogleAuthStateStore`) — developer mode only. The
      Google OAuth state, including live refresh tokens; gitignored and written `0600`.
      It exists because an ad-hoc `swift build` binary's signature changes on every rebuild, so
      the login Keychain re-prompts for access each time. Same note as above: an intentional
      developer-mode substitute for `KeychainAuthStateStore`, not stray state.

## Legacy paths already removed

Neither of these ticked a box on its own — the fields they touch still have other readers — but
both were dead weight removable independently of any migration, and clearing them shrinks what the
ticks above have to untangle later.

- [x] **`logbook.activity_name` was written on every event and read by nothing.**
      `AppState.activity(for:)` — the blob-backed one, as distinct from `categoryActivity(for:)` —
      had exactly one production caller, `HistoryIngestor`, which used only its `name` to fill this
      column. `logbook` itself is still live (`DailyFacetTotals` reads it via
      `loadEvents(overlappingSince:)`) but that reader touches only `paused`, `startedAt`,
      `duration` and `facetID`.
      The column is now written empty and `AppState.activity(for:)` is gone, along with
      `DeviceEventRecord.activityName`. The column itself stays until `logbook` does — it is
      `NOT NULL` and the legacy `000_` table is frozen.
- [x] **`AppDataStore.loadEvents(after:limit:)` had no production callers**, only tests — dead code
      kept alive by its own coverage. Deleted; the four assertions that used it now read through
      `loadEvents(overlappingSince:)` with an epoch-zero cutoff, which returns the same rows.

## Already in the right place — not in scope

Listed so the boundary of this work is clear.

- Keychain: Google OAuth state (`KeychainAuthStateStore`), Google client secret
  (`GoogleClientSecretStore`), device password (`TimeFlipDevicePasswordStore`).
- Database: everything in the `setting` table, plus all device history, categories, faces, icons,
  colours and debug log.

## Notes

- There is no other `UserDefaults` usage, no `@AppStorage`, and no window-frame autosave, so the
  single blob plus the two developer-mode files is the whole of it.
- Moving a field is three steps, not one: give it a home in the database, repoint every reader at
  that home, then delete the field from `PreferencesPayload`. Only the third step ticks the box.
- `PreferencesPayload`, `PreferencesStore`, `UserDefaultsPreferencesStore` and
  `FacetMappingRecord` all disappear once every box above is ticked.
