# Legacy storage removal

**Goal: every piece of persisted state lives in the SQLite database or the Keychain, and nowhere else.**

This lists everything that was persisted outside those two at the branch's fork point — `00a9388`, the merge of `feature/testAutomation` into `main` — so the list is fixed and progress against it is measurable. A box is ticked only when the legacy copy is **gone**, not when the database merely has somewhere to put it.

**11 of 11 done. Nothing is persisted outside SQLite and the Keychain any more.** `PreferencesPayload`, `PreferencesStore`, `UserDefaultsPreferencesStore`, `FaceMappingRecord` and `FaceMapping` are all deleted, along with the `timeflip.preferences` key itself: `ApplicationDelegate.removeLegacyPreferencesBlob` removes it once at launch, because nothing reading a key is not the same as the key being gone, and `UserDefaults` never forgets one on its own. Two dead paths that needed no migration were cleared along the way: see [Legacy paths already removed](#legacy-paths-already-removed).

## UserDefaults — the `timeflip.preferences` blob

One `UserDefaults` key held a JSON-encoded `PreferencesPayload` (`Sources/TimeFlipApp/PreferencesStore.swift`), the only `UserDefaults` key the app ever used. Every field below was a member of that one blob, which is why the key could not go until all of them had. All of them have, so the file, the types and the key are gone. `ColorComponents` was the one thing in that file worth keeping, and now lives in `ColorComponents.swift`.

### Per-face mappings (`faceMappings: [FaceMappingRecord]`)

- [x] **Face name** — free text per face, `""` meaning unassigned. *Done — `face.category_id` → `category.category_name`, which is what the menu bar already displayed.*
- [x] **Face icon** — asset name (`ic_meeting`), `""` for none. *Done — `category.icon_id`, already live for the menu bar and editable on the Categories tab.*

      **The blocker recorded here was already gone.** This entry said both fields were waiting on
      the Faces tab's category-assignment UI. That UI exists: `CategoryAssignmentList` assigns, and
      `TopFaceEditor` had already been repointed at `categoryActivity(for:)` for what it displays.
      What was left was not a migration but three vestiges of one. `TopFaceEditor` still declared a
      `Binding<FaceMapping>` its body never read; `FaceMappingList` and `FaceMappingRow`, the last
      code anywhere reading a face's own name and icon, were defined and never instantiated; and
      `faceMappings` itself survived only as a count of faces and an is-there-a-face-up check, both
      answerable from `TimeFlipConstants`. So the box could have been ticked at any point after the
      Faces tab was re-modelled. Check the readers before trusting a blocker written down earlier.
- [x] **Face colour** — `ColorComponents` (r/g/b/a). *Done — `category.colour_id` → `colour.device_hex`, which now drives the device LED (BLE `0x11`) and the Faces tab's icon tints.* The write follows `$faceCategories` instead of `$faceMappings`, so recolouring a category or reassigning a face is what changes the light.

      **A category with no colour now sends black, i.e. the LED off.** Previously an unset colour
      left whatever the face was last lit with, which made "None" mean "unchanged" — invisible on
      the device and impossible to undo from the UI. `0x11` takes an RGB triple with no separate
      enable, so all-zero is how the protocol says off. On screen the same "no colour" resolves to
      `.primary` instead, since a black-on-black icon would just disappear.
- [x] **Face daily limit** (`limitMinutes`) — whole minutes, `0` = none. *Done — `category.daily_limit`, already editable on the Categories tab and now what the menu bar's over-limit indicator reads.* The only one of the four that needed no new plumbing: `categoryActivity` already resolved the face's `CategoryRecord`, which carries `dailyLimitMinutes`, so the value was in hand.

      **The limit is now per category, not per face** — two faces assigned the same category
      share one, where the blob gave each its own and let the pair drift. The Faces tab's Daily
      Limit stepper is gone with the field, leaving the Categories tab as the only place a limit is
      set. Existing per-face limits in the blob are discarded rather than migrated. The old
      `0...480` cap went with the stepper; `category.daily_limit` is deliberately uncapped.

### Google integration

- [x] **`googleCalendarID`** — the calendar events sync into. *Done — the `calendar_id` key on the existing `google_account` setting row.*
- [x] **`googleCalendarName`** — display name for the above, cached to avoid a lookup. *Done — `calendar_name` on the same row.*
- [x] **`googleClientID`** — OAuth client id. Not a secret (it appears in every OAuth URL), which is why it is not in the Keychain alongside the client secret. *Done — `client_id` on the same row.* Developer mode's `config.json` still overrides it at launch, unchanged.

  All three joined `google_account` rather than taking a row of their own. Sign-out resets only that row's `name` and `email`, so configuration sharing the row is not collateral damage.

### Pairing state

- [x] **`isPaired`** — whether a device is paired. *Done — the existing `paired` setting row, which the app now restores at launch.* In the blob this was only ever a backward-compatibility fallback for `wantsPairing`, written *from* it by `persistPreferences`, so the two always held the same value.
- [x] **`wantsPairing`** — whether the user has asked to be paired, distinct from currently being paired. *Done — deleted outright rather than moved.* It existed to work around `paired` being cleared on every transient disconnect, which lost the intent across a quit while the device was out of range. With `paired` made durable (see below) the two say the same thing, and a second flag to keep in step with the first is a bug waiting to happen.
- [x] **`pairedDeviceName`** — the device name. *Done — the `name` key on the `device_name` setting, written from `AppState.deviceName`.* `pairedDeviceName` itself stayed behind as the Device tab's display value and is no longer persisted at all: the "Not paired" placeholder is a rendering of "no pairing", not a name, and `device_name` deliberately outlives a forget.
- [x] **`pairedDeviceUUID`** — CoreBluetooth peripheral identifier, used to reconnect to the same device rather than rediscovering. *Done — the `uuid` key on the `device_uuid` setting.*

  Moving these turned up a pre-existing muddle rather than causing one: the app treated pairing as something that lapsed whenever the device went out of range, which is what let a device reset behind the app's back pass unnoticed. Pairing is now durable — set by pairing, cleared only by Forget Device — and the transient half lives entirely in the `connection` row. See [Pairing vs connection](database-design.md#pairing-vs-connection).

## Legacy paths already removed

None of these ticked a box above, since the blob is what those boxes track, but each was legacy storage removable on its own terms.

- [x] **`logbook.activity_name` was written on every event and read by nothing.** `AppState.activity(for:)` — the blob-backed one, as distinct from `categoryActivity(for:)` — had exactly one production caller, `HistoryIngestor`, which used only its `name` to fill this column. The column was written empty and `AppState.activity(for:)` deleted, along with `DeviceEventRecord.activityName`; the column itself has now gone with the table.
- [x] **The `logbook` table is retired.** `database/000_logbook.sql` is deleted and no Swift refers to the table. It was still live before this: written on every committed segment by `AppDataStore.append`, read by `DailyFaceTotals` for its daily seed, and purged by `resetCursors` after a factory reset.

      **What replaced each use.** The writer is gone outright, since every caller wrote the same
      segment to `device_event` on the next line. `loadEvents(overlappingSince:)` now reads
      `device_event` with `finalised = 1`, which is what carries the old behaviour across rather
      than a detail of the new query: `logbook` only ever held segments the device had closed out,
      because `HistoryIngestor` committed all but the last frame of a batch. The open segment's
      elapsed time is added separately by the menu bar, so counting it in the seed would count it
      twice. `purgeAllEvents` is deleted with nothing in its place.

      **One deliberate behaviour change.** A factory reset no longer zeroes the day's totals.
      Purging `logbook` was what did that, and `device_event` is never purged: its rows are real
      recorded time, and `time_entry` holds a foreign key into them. The cube restarting its event
      counter says nothing about time already spent, so keeping them is the more defensible answer,
      but it is a change and not a like-for-like port.

      **`finalised = 1` is not an exact translation, which surfaced in two tests.** An entry the
      device has moved past can still be the newest row this app holds, when a history stream is cut
      short before the frame that would close it out. `logbook` called such a row committed;
      `device_event` calls it open. Two `HistoryIngestorTests` cases were using `loadEvents` as a
      proxy for "what got stored" and now read `device_event` directly for that question, which is
      the more honest assertion either way.

      **Migration applied.** `DROP TABLE logbook;` has been run against both `production.sqlite` and
      `test.sqlite`; neither holds the table or its index any more, and
      `scripts/compare-database-to-ddl.sh` reports no differences. Nothing was lost by it, checked
      before rather than assumed: all 34 rows in production had an exact `device_event` counterpart on
      `(event_number, start_epoch)`, with the same face and the same duration to within half a second.
      (Matching on `event_number` alone appeared to show 42 mismatches, which is the join fanning out:
      an event number repeats across counter generations, so it is not a like-for-like key.)
- [x] **`AppDataStore.loadEvents(after:limit:)` had no production callers**, only tests — dead code kept alive by its own coverage. Deleted; the four assertions that used it now read through `loadEvents(overlappingSince:)` with an epoch-zero cutoff, which returns the same rows.

## Already in the right place — not in scope

Listed so the boundary of this work is clear.

- Keychain: Google OAuth state (`KeychainAuthStateStore`), Google client secret (`GoogleClientSecretStore`), device password (`TimeFlipDevicePasswordStore`).
- Database: everything in the `setting` table, plus all device history, categories, faces, icons, colours and debug log.
- The two developer-mode files in `~/Library/Application Support/TimeFlip/`, `config.json` (`DeveloperConfigStore`) and `config.auth.json` (`DeveloperModeGoogleAuthStateStore`). **Not legacy.** They are deliberate developer conveniences that go when the app is production ready, so they are not persisted state that needs a home elsewhere and nothing here is waiting on them. Noted only so a future reader does not file them as an oversight again.

## Notes

- There is no other `UserDefaults` usage, no `@AppStorage`, and no window-frame autosave, so the single blob is the whole of it.
- Moving a field is three steps, not one: give it a home in the database, repoint every reader at that home, then delete the field from `PreferencesPayload`. Only the third step ticks the box.
- `PreferencesPayload`, `PreferencesStore`, `UserDefaultsPreferencesStore` and `FaceMappingRecord` all disappear once every box above is ticked.
