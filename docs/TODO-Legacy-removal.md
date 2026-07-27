# Legacy storage removal

**Goal: every piece of persisted state lives in the SQLite database or the Keychain, and nowhere
else.**

This lists everything that was persisted outside those two at the branch's fork point —
`00a9388`, the merge of `feature/testAutomation` into `main` — so the list is fixed and progress
against it is measurable. A box is ticked only when the legacy copy is **gone**, not when the
database merely has somewhere to put it.

Nothing is ticked yet, and no item can be ticked by deleting code alone — every legacy field
still has at least one live production reader. Several already have a database home and a live
reader too, but the legacy copy is written alongside, which is the thing this list is about.
Two dead paths that needed no migration have already been cleared: see
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

- [ ] **`googleCalendarID`** — the calendar events sync into.
      *No DB home yet.* A `setting` row is the natural fit. Not a secret, so not Keychain.
- [ ] **`googleCalendarName`** — display name for the above, cached to avoid a lookup.
      *No DB home yet.* Same `setting` row as the id.
- [ ] **`googleClientID`** — OAuth client id. Not a secret (it appears in every OAuth URL), which
      is why it is not in the Keychain alongside the client secret.
      *No DB home yet.* A `setting` row.

### Pairing state

- [ ] **`isPaired`** — whether a device is currently paired. **The cheapest item on this list.**
      Neither copy is really in use. The `paired` setting row is written by
      `AppDataStore.recordPaired(_:)` but **never read back** — nothing in `Sources/` loads it, so
      it is a mirror for tests and observers rather than a source of truth. And the blob field is
      only read as a backward-compatibility fallback: `wantsPairing = payload.wantsPairing ??
      payload.isPaired`, immediately followed by an unconditional `isPaired = false`. The stored
      value therefore only matters for payloads written before `wantsPairing` existed. Accept
      dropping those and the blob field can go today, with no database work at all.
- [ ] **`wantsPairing`** — whether the user has asked to be paired, distinct from currently being
      paired. Loaded from the blob, falling back to `isPaired` for payloads written before the
      field existed.
      *No DB home yet.*
- [ ] **`pairedDeviceName`** — remembered device name, shown while disconnected.
      *No DB home yet.*
- [ ] **`pairedDeviceUUID`** — CoreBluetooth peripheral identifier, used to reconnect to the same
      device rather than rediscovering.
      *No DB home yet.*

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
