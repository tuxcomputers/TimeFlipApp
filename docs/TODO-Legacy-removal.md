# Legacy storage removal

**Goal: every piece of persisted state lives in the SQLite database or the Keychain, and nowhere
else.**

This lists everything that was persisted outside those two at the branch's fork point —
`00a9388`, the merge of `feature/testAutomation` into `main` — so the list is fixed and progress
against it is measurable. A box is ticked only when the legacy copy is **gone**, not when the
database merely has somewhere to put it.

**9 of 13 done.** All four pairing fields, all three Google fields and both the per-face daily
limit and colour have moved. What remains is the face name and icon — blocked on the same missing
UI as each other — and the two developer-mode files, which are intentional escape hatches rather
than oversights. `PreferencesPayload` is now nothing but `faceMappings` — the
`timeflip.preferences` key disappears with them. Two dead paths that needed no migration have also
been cleared: see [Legacy paths already removed](#legacy-paths-already-removed).

## UserDefaults — the `timeflip.preferences` blob

One `UserDefaults` key holds a JSON-encoded `PreferencesPayload`
(`Sources/TimeFlipApp/PreferencesStore.swift`). It is the only `UserDefaults` key the app uses.
Every field below is a member of that one blob, so the key itself only disappears once all of them
have moved.

### Per-face mappings (`faceMappings: [FaceMappingRecord]`)

- [ ] **Face name** — free text per face, `""` meaning unassigned.
      *DB home:* `face.category_id` → `category.category_name`, which already exists and is what
      the menu bar displays. The Faces tab, which still shows and edits it, is now the **only**
      reader — `HistoryIngestor` no longer derives a name from it (see
      [Legacy paths already removed](#legacy-paths-already-removed)). Removing that last reader
      needs the Faces tab's category-assignment UI (see
      [TODO-features-under-development.md](TODO-features-under-development.md) § Faces).
- [ ] **Face icon** — asset name (`ic_meeting`), `""` for none.
      *DB home:* `category.icon_id`, already live for the menu bar and editable on the Categories
      tab. Only the Faces tab still reads the blob field, so the same blocker as the name.
- [x] **Face colour** — `ColorComponents` (r/g/b/a). *Done — `category.colour_id` →
      `colour.device_hex`, which now drives the device LED (BLE `0x11`) and the Faces tab's icon
      tints.* The write follows `$faceCategories` instead of `$faceMappings`, so recolouring a
      category or reassigning a face is what changes the light.

      **A category with no colour now sends black, i.e. the LED off.** Previously an unset colour
      left whatever the face was last lit with, which made "None" mean "unchanged" — invisible on
      the device and impossible to undo from the UI. `0x11` takes an RGB triple with no separate
      enable, so all-zero is how the protocol says off. On screen the same "no colour" resolves to
      `.primary` instead, since a black-on-black icon would just disappear.
- [x] **Face daily limit** (`limitMinutes`) — whole minutes, `0` = none. *Done —
      `category.daily_limit`, already editable on the Categories tab and now what the menu bar's
      over-limit indicator reads.* The only one of the four that needed no new plumbing:
      `categoryActivity` already resolved the face's `CategoryRecord`, which carries
      `dailyLimitMinutes`, so the value was in hand.

      **The limit is now per category, not per face** — two faces assigned the same category
      share one, where the blob gave each its own and let the pair drift. The Faces tab's Daily
      Limit stepper is gone with the field, leaving the Categories tab as the only place a limit is
      set. Existing per-face limits in the blob are discarded rather than migrated. The old
      `0...480` cap went with the stepper; `category.daily_limit` is deliberately uncapped.

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

- [x] **`isPaired`** — whether a device is paired. *Done — the existing `paired` setting row,
      which the app now restores at launch.* In the blob this was only ever a
      backward-compatibility fallback for `wantsPairing`, written *from* it by
      `persistPreferences`, so the two always held the same value.
- [x] **`wantsPairing`** — whether the user has asked to be paired, distinct from currently being
      paired. *Done — deleted outright rather than moved.* It existed to work around `paired`
      being cleared on every transient disconnect, which lost the intent across a quit while the
      device was out of range. With `paired` made durable (see below) the two say the same thing,
      and a second flag to keep in step with the first is a bug waiting to happen.
- [x] **`pairedDeviceName`** — remembered device name, shown while disconnected. *Done — the
      `name` key on `paired_device`.* The "Not paired" placeholder is a display default and is
      stored as absent rather than as that string.
- [x] **`pairedDeviceUUID`** — CoreBluetooth peripheral identifier, used to reconnect to the same
      device rather than rediscovering. *Done — the `uuid` key on `paired_device`.*

  Moving these turned up a pre-existing muddle rather than causing one: the app treated pairing as
  something that lapsed whenever the device went out of range, which is what let a device reset
  behind the app's back pass unnoticed. Pairing is now durable — set by pairing, cleared only by
  Forget Device — and the transient half lives entirely in the `connection` row. See
  [Pairing vs connection](database-design.md#pairing-vs-connection).

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
      column. `logbook` itself is still live (`DailyFaceTotals` reads it via
      `loadEvents(overlappingSince:)`) but that reader touches only `paused`, `startedAt`,
      `duration` and `faceID`.
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
  `FaceMappingRecord` all disappear once every box above is ticked.
