# Feature under development

- [x] Categories
- [x] Faces
- [x] Time logs
- [ ] Calendar sync
- [ ] Sync to TimeFlip cloud
- [ ] Projects
- [x] Device rename

## Categories

- Unlimited categories, created by the user.
- Any category can be assigned to any face; the same category can be assigned to multiple faces at the same time.
- Assigning a category the user types that doesn't exist yet creates it by default — this is the default action; the user also has the option to instead **rename** an existing category. Since historical data (e.g. `time_entry`) links to `category` by `category_id`, a rename automatically carries forward everywhere that history is displayed/reported — no backfill needed.
- Assignment is done by picking from a list (dropdown) of existing categories.
- New `active` column on the `category` table. An inactive (deactivated) category:
  - No longer appears in the assignment dropdown.
  - Can still be reported against, same as an active one.
  - Rationale: categories like a JIRA ticket accumulate time against them but eventually stop being used — deactivating hides them from future assignment without losing their history.

(Note: `face.category_id` is already a plain FK, many faces -> one category, so multiple faces already share a category with no schema change. The new work is the `active` column plus the create-if-missing and active-filtered-dropdown behavior.)

### Telling retired namesakes apart

`UN1_category` allows one *active* category per name and any number of retired ones, so several retired categories can end up sharing a name, each owning its own history. They are then hard to tell apart, and two pieces of work follow from that. Neither is done.

The create flow no longer guesses between them: typing a name that matches more than one retired category drops the reinstate button and points at the Inactive list, where each is at least a separate row. That much is built. What is missing is any way to know *which* row is which.

- **Show what distinguishes them on the row.** The reason to reinstate a category is the history attached to it, so what the user actually needs is which one holds their data: total time recorded against it, and when it was last used. That needs `time_entry`, which has no writer yet (the same dependency parking two tests in `CategoryStoreTests`). Until then the cheapest meaningful signal is when it was retired -- a `retired_at` column, shown as "Retired 3 Mar 2026" on each inactive row. Per `database/CLAUDE.md` that is two columns, since every timestamp needs its `timezone_id` FK.
- **Then offer a picker.** With rows that can be told apart, the create flow can list the matches and let the user choose, instead of sending them elsewhere. Strictly downstream of the point above: without labels it is a column of identical buttons, which is the blind pick again with more steps.

A third option was considered and rejected: forbidding duplicate names among *retired* categories too, by requiring a rename when retiring onto a namesake. It would make the whole problem disappear, but each retired row owns distinct history, so they are not interchangeable and merging them is not automatically safe. Worth revisiting only if the duplicates turn out not to be worth keeping.

## Faces

- Any **active** category can be assigned to a face.
- The same category can be assigned to multiple faces at once.
- Two ways to assign:
  1. The list on the right-hand side (the existing per-face settings list).
  2. Click the **current face** (the device's currently active face) to open a dropdown of active categories; typing into the field filters the dropdown by the typed text.

- Category assignment **replaces** today's free-text per-face editing: a face's identity becomes its assigned `category_id`, and the category's own name/icon/colour (already columns on `category`) are what display for that face. The current free-text name field (`TopFaceEditor`'s `nameBinding` in `SettingsViews.swift`) goes away.

(Note: today, `TopFaceEditor` in `SettingsViews.swift` edits a face's name/icon/colour directly per row, independent of the `category` table — there's no category-picker dropdown yet, filtered or otherwise, and no "click the current face to assign" gesture. This is a real re-model of how a face's display comes to be, not just an added picker, on top of the `active`-aware category list from the Categories section above.)

## Time logs

- When a `device_event` row becomes finalised (closed out by a later event), a new `time_entry` row is created for it — one finalised `device_event` -> one `time_entry`.
- The new row's `category_id` is the category the face was linked to **at that time** — captured at creation, not looked up later. If the face's category assignment changes afterward, past `time_entry` rows keep pointing at the category they were actually logged against.
- Every other `time_entry` column is calculated at creation time: `started_at`/`ended_at` (from the `device_event`'s start and the point it closed), `duration_seconds`, `total_cost` (from the category's `cost`), etc. -- nothing is backfilled or recalculated after the fact.

Built on `bugfix/stepperArrowDisplay`'s parent, `feature/timeEntry` (PR #43). `AppDataStore.createTimeEntriesForFinalisedEvents` runs at the end of every `recordDeviceEvent`, so an entry appears as the following flip closes a segment out. `sweepTimeEntries(trigger:)` is the wider pass that drops the `processed` condition to find rows wrongly marked done, triggered on launch, on history ingest, and before a face changes category -- before, so the entry can still resolve the face-to-category link as it was when the time was spent. `UN1_time_entry` makes one entry per `device_event` a constraint rather than a convention. See [Operation Spec § 3](operation-spec.md).

Segments shorter than `blip_time` get no entry and are marked `processed`, which is the cube being turned past a face rather than time spent on it.

(Note: one bullet above is **not** built. `total_cost` is never calculated from the category's `cost` -- the insert omits the column and takes the schema's `DEFAULT 0`, so every entry so far reads zero. Left until there is something that reads it, since nothing charges for time yet; the cost-at-creation rule is the part to preserve when it is added, because a rate change afterwards must not silently reprice history.)

## Calendar sync

- The user creates a new calendar or selects an existing one on the **App** tab.
- When a `time_entry` row is created, a sync process runs against it:
  1. Create the calendar event, with the `time_entry` id in the event's note/description.
  2. Read back the event(s).
  3. Check the read-back event's properties against the `time_entry` record to confirm the created event is correct.
  4. Once confirmed, mark the `time_entry` row's sync to calendar as ticked (`synced_to_google_calendar = 1`).

(Note: the App-tab calendar create/select UI, `GoogleCalendarEvent` model, and `GoogleCalendarClient.insertEvent` already exist (`ReportSettingsView.swift`, `GoogleCalendarClient.swift`) -- and `time_entry.synced_to_google_calendar` is already reserved for this in the schema, per `docs/operation-spec.md` § 5. What's still missing: the actual background process that reads unsynced `time_entry` rows and drives all four steps above, the calendar event's description carrying the `time_entry` id (`GoogleCalendarEvent.description` exists but nothing currently populates it that way), a read-back call (`GoogleCalendarClient` has no list/get-single-event method yet, only `insertEvent`), and the property-comparison check. This feature depends on Time logs above actually writing `time_entry` rows before it has anything to sync.)

## Sync to TimeFlip cloud

- Design intent to be captured.

(Note: nothing in `Sources/` talks to a TimeFlip cloud API today -- no HTTP client, endpoint, account or token for it exists; the only cloud integration currently built is Google Calendar. The vendor's API is documented in `docs/TimeFlip API Documentation 05.2025.pdf`, which is where the shape of this work will come from.)

## Projects

- The user creates projects.
- Multiple categories can be associated with a single project, each carrying its own cost.
- Reporting can be grouped by project.

(Note: `project` (`006_project.sql`) is currently id/name only -- "for now", per its own comment -- and `category.project_id` already links many categories to one project, so that part of the association is already schema-supported; each category's own `cost` is what rolls up under the project. What's missing: any project create/manage UI at all (no `Project`-named view exists anywhere in `Sources/`), and any reporting query that groups by `project_id` -- today's reports (`ReportSettingsView.swift`) don't reference `project` at all.)

## Device rename

- The user can give the physical TimeFlip its own name.
- The Scan for Devices list must match **both** the vendor default name and the stored custom name, so a renamed cube is still findable.

### Storage: `device_uuid` and `device_name` (done)

The old single `paired_device` row held the peripheral uuid and the name together, under one lifetime. It is now **two rows**, because the two need different ones:

| Row | Forget Device | Factory reset (`0xFF`) |
|---|---|---|
| `device_uuid` | cleared | cleared |
| `device_name` | **kept** | cleared |

The name outliving Forget Device is the whole point of the split. Forgetting a device does not un-rename the cube, so a cube called e.g. `Solid cube` goes on advertising that and nothing else; if the app throws the string away at exactly the moment it needs to scan again, the filtered scan cannot find it and the **All Devices** tick box is the only way back. A factory reset is the opposite case: the cube really has reverted to the vendor name, so the remembered one is now wrong and keeping it would make the filter match a name that no longer exists.

`device_name` mirrors the cube rather than recording a wish: it is re-read from the peripheral on every connect. That is deliberate, and it means the row cannot be used to *restore* a name after a factory reset -- there is nothing left saying what the user had chosen. Reverting to the vendor name when the device is wiped is the honest outcome, and is why factory reset clears the row rather than trying to reinstate from it.

`AppState.pairedDeviceName` stays display-only and is no longer persisted, so the Device tab's "Not paired" placeholder cannot reach the database as if it were a device called that -- which is what let the name survive a forget without the tab claiming a pairing that is gone.

### The rename UI (done)

Right-clicking the **Name** row on the Device tab offers **Rename**, which turns the value into an inline field. Return submits, Escape abandons it. The same shape as the Categories tab's rename, which is how this app already renames things.

The menu item is disabled while the device is unreachable: the cube is what holds the name, and `0x15` would only fail on the driver's not-logged-in guard.

**What the device actually accepts.** The `0x15` entry in `docs/TimeFlip2 BLE Protocol v4.3.md`: `0xZZ … 0xZZ - name (18 symbols MAX. ASCII coding)`. Both limits are the device's, not choices this app made. The app adds one restriction of its own on top: control characters are excluded as well, leaving printable ASCII `0x20`-`0x7E`, since a tab or a NUL in a name that appears in every nearby device's scan list is a rendering problem for no gain. Note `0x2A00` reads up to 20 bytes, so only the *write* is capped at 18.

**Where the 18-character limit is enforced, and why in more than one place.** `DeviceNameRules` owns the number; `TimeFlipBLEDevice.maximumDeviceNameLength` now defers to it, so the field and the write cannot come to disagree.

- *While typing*, the field truncates at 18. What is on screen is what will be written.
- *At submit*, the length is **checked** rather than truncated. From the field that is unreachable, which is the point: it stands between the device and a paste that outruns the truncation, or any later caller that does not come through this field.
- *At the write*, `setDeviceName` refuses over-18 and non-ASCII by returning false.

Characters are deliberately **not** filtered as they are typed. An emoji that vanished on the keystroke reads as a broken keyboard, with nothing to say why. It is left visible, refused at submit, and the alert names the reason -- and **the field stays open with the text still in it**, so a rejected name can be fixed rather than retyped from the context menu.

**What the refusal alerts must say**, all three parts required rather than stylistic:

1. That the **TimeFlip** cannot store the name, naming the device rather than the app.
2. That this is TimeFlip's limit, "not something this app has decided". A limit with no owner reads as the app being fussy, and leaves the user thinking some other app would allow an emoji. The attribution is also simply true: the vendor's own spec defines the field, and a name outside it cannot reach the device at all.
3. What **will** work -- up to 18 characters of letters, numbers, spaces and ordinary punctuation. Being told a name is wrong without being told what is right is guessing at an invisible rule.

A failed *write* is deliberately excluded from all of that: the device not answering is a different problem from a name it cannot hold, and quoting the character rules at a connection fault sends the user looking in the wrong place. `DeviceNameRulesTests` asserts each of these.

The name is adopted locally only once the device confirms the write. A failed write leaves both the Device tab and `device_name` saying what the cube still answers to, which matters beyond cosmetics: `device_name` is what the scan filter is to match a renamed cube on, so a name the device never took would be a name nothing could be found by.

**Note for the device checklists**: a SwiftUI `.contextMenu` is invisible to accessibility -- it reports zero menus and `AXShowMenu` opens nothing (established while building the Categories tab, see `Tests/Interactive/08i-categories-tab-checklist.md`). Driving this needs `act_cgevent_context_menu_pick` in `scripts/testrunner/actions.py`, which exists and works.

### Confirmation, which the device makes impossible (done as far as it can be)

Both items that stood here are closed.

**The checklists exist.** `Tests/Bench/09b-device-rename-checklist.md` covers the whole feature and was last run against the cube on 2026-08-02; `Tests/Interactive/09i` is a stub, because renaming needs the device switched on but never a hand on it. That run is what verified the part whose failure mode was losing the cube entirely: a renamed device is still found on the next launch, by the remembered `device_name` rather than by the vendor default.

**A rename cannot be confirmed at the time it is made, and the app now says so instead of pretending otherwise.** There is no acknowledgement for `0x15` and no useful read-back within the session, both measured (see the note below). `peripheralDidUpdateName(_:)` is implemented and fires about two seconds into the *following* connection, which is the confirmation, so a rename is reconciled at the next connect. What the app adds on top is honesty about the gap: `DeviceNameRules.renameLagNotice` puts a caption on the Device tab saying the new name is stored and that the cube will keep advertising the old one until it reconnects, and `AppState.clearRenameLagNoticeIfCaughtUp(reported:)` drops the caption once the two names agree. The wording blames the firmware for the advertised name only, not for the rename, because the rename itself does work.

For a user who wants the new name to appear now rather than at the next reconnect, [Configuration § renaming](configuration.md) has the forget-and-rescan sequence.

(Note: the four findings below are what shaped the feature, all confirmed against the vendor spec and the hardware. They are kept because each one contradicts something this file previously asserted, and the corrections are worth more than the space:

**There is no usable read-back within the session that renamed the device, despite `0x2A00` being readable.** Measured on the hardware 2026-08-01: after a rename the app polled `TimeFlipDevice.deviceName` (which is `CBPeripheral.name`, the platform's own reading of `0x2A00`) **120 times over 30 seconds** and it never moved off the previous name. The value refreshes only when CoreBluetooth next connects and re-reads GAP, so it is connection-gated, not time-gated: no wait, however long, will see the change from within the same connection.

**The next connection does report it, and does so actively.** `peripheralDidUpdateName(_:)` fires about two seconds into the following connection, on all three of three renames tested. An earlier version of this note said it had "never fired once" -- that was concluded from the 30-second poll alone, which by definition could not observe a callback that only arrives after a reconnect. It is wired up and is what corrects the name a first pairing adopts from the stale cache.

So a rename gets **no confirmation at all** at the time it is made. The device never updates the command result characteristic for `0x15`, and `performCommand`'s check does not notice because a stale response from an unrelated command is neither one nor two bytes long and so skips validation entirely (see `docs/timeflip2-firmware-observations.md`, finding 2). Everything the app needs the name for -- the stored `device_name`, the Device tab, and the scan filter -- is updated from what was written rather than from a read. Forcing a disconnect/reconnect purely to refresh the cached value was considered and rejected: it costs a session drop, a re-login and a history re-sync to learn something already known.

Note this cuts against an earlier claim in this file that the name "has a real read-back, unlike LED brightness and blink interval". Readable in the GATT sense, yes; useful for confirming a write you just made, no.

**The displayed name now comes from the device.** It used to be a literal: `ApplicationDelegate` called `appState.confirmConnected(name: "TimeFlip", uuid: nil)` with the string spelled out in the source, so the Device tab read `TimeFlip` no matter what the cube was called, while the scan showed `TimeFlip v2.0` from `peripheral.name`. That call now passes `device?.deviceName`, so the tab, the in-memory state and `device_name` all agree with the cube (fixed 2026-08-01, confirmed live).

**18 ASCII characters, and the two limits differ.** The spec caps the `0x15` write at 18 symbols, ASCII only, while `0x2A00` reads up to 20. `setDeviceName` enforces the write limit by returning false, so an over-long or non-ASCII name would fail with only a debug line to show for it. Validate in the rename UI, not just at the BLE call.

**A renamed cube disappears from the scan, and that loses it on the very next launch.** Reconnecting is a **scan**, not a lookup of the stored `device_uuid`: `connect()` calls `scanAndConnect()`, and nothing in `TimeFlipBLEDevice` ever calls `retrievePeripherals(withIdentifiers:)`. The filter is `serviceMatches || nameMatches`, and the code's own comment records that the service UUID is **not** reliably advertised by this hardware, so the name match is in practice the only thing that finds the cube.

An earlier version of this note claimed the opposite -- that a rename was "harmless while the device stays paired, because reconnects go straight to the stored uuid". That was wrong, and it is why the scan work was filed as later rather than as a prerequisite. Renaming a cube to "Hazza" on 2026-08-01 made every reconnect time out from the next launch onwards; the log shows `connect begin`, `connect radio powered`, and then nothing. **Fixed** by `DeviceNameRules.matchesKnownDevice`, which also matches the remembered `device_name`, fed to the driver as `rememberedDeviceName` before every connect and again the instant a rename lands.

The **All Devices** tick box (`scanAllDevices`, `TimeFlipSettingsView`) turns the filter off entirely and remains the manual way back if a cube is ever renamed by something other than this app -- but it is a backstop now, not the recovery path, and it was never reachable while `isPaired` was true anyway, since that state shows Forget/Reset instead of Scan.

One useful interaction: `0xFE` (reset task info) deliberately leaves the name untouched, so only a full `0xFF` factory reset clears it -- which is why `0xFE` touches neither row and `0xFF` clears both. The device-test runner's end-of-run factory reset therefore returns the cube to the vendor name and empties `device_name` with it, leaving nothing to repair afterwards.

**The firmware is inconsistent with itself about the name, and the spec does not mention it.** The `0x15` entry in `docs/TimeFlip2 BLE Protocol v4.3.md` is two lines -- a length byte and "18 symbols MAX. ASCII coding" -- and says nothing about when a rename takes effect or where it shows. What the hardware actually does, all measured on 2026-08-01:

- The GAP Device Name (`0x2A00`, what `CBPeripheral.name` reports) **does** change.
- The advertised local name **does not**: a cube whose GAP name read "Hazza cuber" was still advertising `TimeFlip v2.0`, across three successive renames.
- The change is not observable until the central reconnects, at which point CoreBluetooth notices it and fires `peripheralDidUpdateName(_:)`.

The two names disagreeing is what made a renamed cube unfindable, and the advertised name never changing is what makes it findable again, so both halves matter. Whether the cube applies a rename immediately or defers it is **not determinable from macOS**, since the host only re-reads GAP on connect; answering that needs a second central with no cache of this device.)
