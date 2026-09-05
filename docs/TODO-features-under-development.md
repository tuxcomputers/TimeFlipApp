# Features under development

**Read this first.** This file is a running record of decisions, kept in the order they were taken, and several
sections predate the ground-up rebuild -- so a section can be an accurate account of a decision and still describe
code that no longer exists. Sections written against the previous implementation say so at the top. For what is built
in the app **as it stands**, read the code: `docs/rebuild.md` used to answer that and was deleted once the rebuild
was done, the checklist above being what is left of it. This file is the reasoning behind individual features and is
worth reading before changing one.

- [x] Categories
- [x] Faces
- [x] Time logs
- [x] Calendar sync
- [ ] Sync to TimeFlip cloud
- [ ] Projects
- [ ] Cost time entry
- [x] Device rename
- [x] Report
- [x] Timing by hand (was "Manual mode")

## Categories

- Unlimited categories, created by the user.
- Any category can be assigned to any face; the same category can be assigned to multiple faces at the same time.
- Assigning a category the user types that doesn't exist yet creates it by default — this is the default action; the user also has the option to instead **rename** an existing category. Since historical data (e.g. `time_entry`) links to `category` by `category_id`, a rename automatically carries forward everywhere that history is displayed/reported — no backfill needed.
- Assignment is done by picking from a list (dropdown) of existing categories.
- New `active` column on the `category` table. An inactive (deactivated) category:
  - No longer appears in the assignment dropdown.
  - Comes off any face it was assigned to, which go back to `Unassigned` -- otherwise a face keeps showing a category the dropdown no longer offers, and nothing but assigning something else over it can clear that.
  - Cannot be deactivated at all while a **locked** face holds it, since that face has been told to keep what it has. The Categories tab disables the Active box and its tooltip names the face; unlocking it on the Faces tab is the way through.
  - Can still be reported against, same as an active one.
  - Rationale: categories like a JIRA ticket accumulate time against them but eventually stop being used — deactivating hides them from future assignment without losing their history.

(Note: `face.category_id` is already a plain FK, many faces -> one category, so multiple faces already share a category with no schema change. The new work is the `active` column plus the create-if-missing and active-filtered-dropdown behavior.)

### Telling retired namesakes apart

`UN1_category` allows one *active* category per name and any number of retired ones, so several retired categories can end up sharing a name, each owning its own history. They are then hard to tell apart, and two pieces of work follow from that. The first is done.

The create flow no longer guesses between them: typing a name that matches more than one retired category drops the reinstate button and points at the Inactive list, where each is at least a separate row. That much is built. What was missing is any way to know *which* row is which.

- **Show what distinguishes them on the row.** Built. The Inactive list carries a **Last used** column: the end of that category's most recent `time_entry`, or `Never` for one that has recorded none (`CategoryLastUsedText`, filled by `CategoryStore`). Two namesakes whose history differs are separable at a glance, and one with nothing behind it says so rather than sitting blank.

  **Total time recorded against each will not be built** (decided 2026-08-10). It was the other half this section once asked for, on the grounds that last used answers how recently rather than how much, so a category used once for a minute reads the same as one used daily for a year. That distinction is real but is not worth a second aggregate over `time_entry` on every category load: the question this section exists to answer is *which of these two rows is mine*, and a date answers it. Reopen it only if two namesakes turn up that were genuinely last used at the same time.

  This section used to propose a `retired_at` column instead, on the grounds that a last-used date needed `time_entry`, which had no writer at the time. It has one (`TimeEntryRecorder`), so the better signal was available and `retired_at` is no longer wanted: when a category was retired says nothing about the history behind it, which is the actual question being asked. That dependency was also the stated reason two tests in `CategoryStoreTests` are commented out; the reason no longer holds, so they are worth reinstating on their own merits.
- **Let a namesake be given its own name.** Built. The Inactive list's name is editable, by the same click on the same cell the Active list uses, so a row that has been told apart by its Last used date can be made to *stay* apart rather than being re-identified every time the list is opened. This is the half that turns the point above from a diagnosis into a fix, and it was the archive's behaviour too (`retiredRow` drew the same editable field the active row drew, behind a right-click *Edit*).

  It also carries a rule the archive got wrong. `UN1_category` covers active rows only, so a retired row may take an *active* row's name; the archive branched on the row in the way rather than the row being renamed and refused that, enforcing a constraint the database does not have. It is now confirmed instead, and the dialogue says the cost: while the two share a name the retired one cannot be reinstated, which is the one thing an active namesake really does block.
- **Then offer a picker.** With rows that can be told apart, the create flow can list the matches and let the user choose, instead of sending them elsewhere. This was blocked on the point above and no longer is: the rows now carry a date, so a picker would list distinguishable options rather than the column of identical buttons that made it a blind pick with extra steps.

  **Still worth building, but less urgent than it was.** A rename lets somebody clear the ambiguity themselves and permanently, where a picker only helps them navigate it each time they meet it. Two namesakes that nobody ever renames are still the case a picker answers.

A third option was considered and rejected: forbidding duplicate names among *retired* categories too, by requiring a rename when retiring onto a namesake. It would make the whole problem disappear, but each retired row owns distinct history, so they are not interchangeable and merging them is not automatically safe. Worth revisiting only if the duplicates turn out not to be worth keeping.

## Faces

- Any **active** category can be assigned to a face.
- The same category can be assigned to multiple faces at once.
**Built, and the gesture landed simpler than either option here.** There is one way to assign, not two: turn the cube
to the face, then click a category in the list. No dropdown, no text field on the face row, and nothing to filter --
the list on the right *is* the picker, and the face the cube is resting on is what it applies to.

The two options originally written down were a per-face list and a click-the-current-face dropdown. What made both
unnecessary is that the cube already selects the face: a physical device resting on a side is a selection, so
re-implementing one on screen would have been a second way to say the same thing.

- Category assignment **replaced** free-text per-face editing: a face's identity is its `category_id`, and the
  category's own name, icon and colour are what display for that face. The previous app's per-face name field
  (`TopFaceEditor`'s `nameBinding`, `Archive/TimeFlipApp/SettingsViews.swift`) is gone with the rest of that file.
- What a click means is one rule, `FacesTabRules.Click`, read twice -- by the list to decide whether its rows are
  live, and by the click to decide what it does -- so the drawing and the action cannot disagree. That matters because
  a click can mean four things: assign to the face, start the app's own clock, refuse because the face is locked, or
  refuse because there is a cube on record that has not been reached.

## Time logs

- When a `device_event` row becomes finalised (closed out by a later event), a new `time_entry` row is created for it — one finalised `device_event` -> one `time_entry`.
- The new row's `category_id` is the category the face was linked to **at that time** — captured at creation, not looked up later. If the face's category assignment changes afterward, past `time_entry` rows keep pointing at the category they were actually logged against.
- Every other `time_entry` column is calculated at creation time: `started_at`/`ended_at` (from the `device_event`'s start and the point it closed), `duration_seconds`, `total_cost` (from the category's `cost`), etc. -- nothing is backfilled or recalculated after the fact.

Built. `TimeEntryRecorder.consider(deviceEventID:)` is called by `DeviceEventRecorder` the moment it finalises a row,
so an entry appears as the following flip closes a segment out. **It is handed an id and reads the row itself**, the
table being what is true about that segment; details passed as arguments would be a second copy that can differ from
it. `UN1_time_entry` makes one entry per `device_event` a constraint rather than a convention. See
[Operation Spec § 3](operation-spec.md).

There is **no periodic sweep**, which the previous app had (`sweepTimeEntries`) and which `setting.time_entry_check`
was seeded for. Conversion is driven by a segment closing instead. The cost is stated in the operation spec: lowering
`blip_time` no longer retroactively converts the segments an earlier, higher threshold skipped.

Segments shorter than `blip_time` get no entry and are marked `processed`, which is the cube being turned past a face rather than time spent on it.

(Note: one bullet above is **not** built and has been split out as [Cost time entry](#cost-time-entry) rather than left as a footnote here. `total_cost` is never calculated from the category's `cost`: the insert omits the column and takes the schema's `DEFAULT 0`, so every entry so far reads zero. Everything else in this section is built.)

## Calendar sync

- The user creates a new calendar or selects an existing one on the **App** tab.
- When a `time_entry` row is created, a sync process runs against it:
  1. Create the calendar event, with the `time_entry` id in the event's note/description.
  2. Read back the event(s).
  3. Check the read-back event's properties against the `time_entry` record to confirm the created event is correct.
  4. Once confirmed, mark the `time_entry` row's sync to calendar as ticked (`synced_to_google_calendar = 1`).

Built. `CalendarSync` runs all four steps, triggered by `TimeEntryRecorder.onEntryRecorded` and again whenever a calendar is settled on the App tab, and it sweeps every row still at `synced_to_google_calendar = 0` rather than only the one just recorded. The event's title is the category name and its description carries both the `time_entry` id and the `device_event` id.

Two decisions worth knowing, both in `GoogleEventRules`:

- The **event id is derived** from the `time_entry` id (`facet4213`) instead of being stored, so a repeated insert collides with Facet's own earlier event (Google answers 409) rather than making a duplicate, and the read-back can address it directly.
- The **times carry the zone the entry was recorded in**, from `time_entry.start_timezone_id`, not the machine's current zone. The archive sent `TimeZone.current` for every event, which files an entry recorded elsewhere at the right clock time in the wrong zone.

(Confirmed on a real account, 2026-08-15: 41 entries created and verified in one pass, and the 409 path exercised by a retry meeting its own earlier event. Two faults only real data found, both fixed: an entry whose `duration_seconds` carried a fraction could never verify, because the body truncated to whole seconds and the comparison did not; and one unverifiable row stopped the whole pass, leaving 39 good entries behind it.

Still worth knowing before this is turned on against a database with history: **a first sweep sends every unsynced entry there is**, oldest first, in batches of 50 and about a second each. `production.sqlite` currently holds 82, spanning 2026-07-28 to 2026-08-13, and its `calendar_id` is still set from an earlier sign-in -- so connecting there delivers two and a half weeks of history at once. A cutoff, if one is wanted, is one clause in `CalendarSync.pendingEntries`.)

## Sync to TimeFlip cloud

- Design intent to be captured.

(Note: nothing in `Sources/` talks to a TimeFlip cloud API today -- no HTTP client, endpoint, account or token for it exists; the only cloud integration currently built is Google Calendar. The vendor's API is documented in `docs/TimeFlip API Documentation 05.2025.pdf`, which is where the shape of this work will come from.)

## Projects

- The user creates projects.
- Multiple categories can be associated with a single project, each carrying its own cost.
- Reporting can be grouped by project.

(Note: `project` (`006_project.sql`) is currently id/name only -- "for now", per its own comment -- and `category.project_id` already links many categories to one project, so that part of the association is already schema-supported; each category's own `cost` is what rolls up under the project. What's missing: any project create/manage UI at all (no `Project`-named view exists anywhere in `Sources/`), and any reporting query that groups by `project_id` -- the [Report](#report) tab groups by category only and doesn't reference `project` at all. Note that the archive's `ReportSettingsView.swift`, despite its name, was the **App** tab and never the report; it took the name first, which is why that app's tab enum's `.report` case had to be renamed `.app` when the real one arrived.)

## Cost time entry

- A category's `cost` is a rate **per hour**, not a flat charge per entry. So a `time_entry`'s `total_cost` is that rate applied to its `duration_seconds`: `cost * duration_seconds / 3600`, both sides in whole cents.
- It is captured, not looked up later: changing a category's `cost` afterwards must leave every existing `time_entry` exactly as it was, the same way `category_id` is captured rather than resolved at read time.
- Reporting can total cost, per category and (with Projects) per project.

(Note: the column exists and is written by nobody. `time_entry.total_cost` is `INTEGER NOT NULL DEFAULT 0` and the insert in `TimeEntryRecorder` omits it, so every entry created so far reads zero -- this was split out of Time logs, whose spec called for it, rather than left as a footnote there. `category.cost` is likewise `INTEGER NOT NULL DEFAULT 0` and there is no UI anywhere that sets it, so the input side is missing too.

Both columns are **whole cents**, per [Database Design](database-design.md) (`250` = \$2.50), so money never touches a float, and `cost` is a rate per hour. That leaves one thing open:

**How the result rounds.** `cost * duration_seconds / 3600` will rarely land on a whole cent, and at these durations the remainder is most of the value: a two-minute segment at \$60/hour is 200 cents exactly, but at \$55/hour it is 183.33. Rounding to the nearest cent per row is the obvious rule and is what to implement absent a reason otherwise. Worth writing down rather than leaving to the first implementation, because a report that sums the stored `total_cost` values and one that recomputes from the durations will otherwise disagree by a few cents with neither being wrong, and the fix then has to pick a winner retrospectively. The safe convention: **the stored value is the price**, and anything reporting on it sums rows rather than re-deriving them.

No currency column exists anywhere, which is fine for one user with one currency and worth knowing before a second one turns up.)

## Device rename

**Built** (2026-08-30). The Device tab's Name row is renamed by clicking it, `0x15` goes to the cube, and the row is
written only once the cube has taken the write. What is kept below is the design and, in particular, the measured
findings at the end: they are facts about the hardware and so still true, and each one contradicts something this file
once asserted.

- The user can give the physical TimeFlip its own name. **Built** -- `DeviceNameRules` decides, `DeviceCommandRules
  .setName` carries it, and `SettingsWindowController.renameDevice` sends it.
- The Scan for Devices list must match **both** the vendor default name and the stored custom name, so a renamed cube
  is still findable. **Built**, and it matches the previous name too (`DeviceScanRules`).

### Storage: `device_uuid` and `device_name` (done, and carried into the rebuild)

The old single `paired_device` row held the peripheral uuid and the name together, under one lifetime. It is now **two rows**, because the two need different ones:

| Row | Forget Device | Factory reset (`0xFF`) |
|---|---|---|
| `device_uuid` | cleared | cleared |
| `device_name` | **kept** | cleared |

The name outliving Forget Device is the whole point of the split. Forgetting a device does not un-rename the cube, so a cube called e.g. `Solid cube` goes on advertising that and nothing else; if the app throws the string away at exactly the moment it needs to scan again, the filtered scan cannot find it and the **All Devices** tick box is the only way back. A factory reset is the opposite case: the cube really has reverted to the vendor name, so the remembered one is now wrong and keeping it would make the filter match a name that no longer exists.

`device_name` mirrors the cube rather than recording a wish: it is re-read from the peripheral on every connect. That is deliberate, and it means the row cannot be used to *restore* a name after a factory reset -- there is nothing left saying what the user had chosen. Reverting to the vendor name when the device is wiped is the honest outcome, and is why factory reset clears the row rather than trying to reinstate from it.

`AppState.pairedDeviceName` stays display-only and is no longer persisted, so the Device tab's "Not paired" placeholder cannot reach the database as if it were a device called that -- which is what let the name survive a forget without the tab claiming a pairing that is gone.

### The rename UI (built)

**Clicking the Name row opens it**, which is the one place the rebuild departs from the archive: that app hid the
rename behind a right-click menu with a single **Rename** item in it, and `EditableNameCell` exists because that is a
gesture nobody finds. It is the same control the Categories tab renames with and the App tab names its calendar with,
so renaming the cube is the same act as renaming anything else here. Return submits, Escape abandons it, and a click
elsewhere abandons it too.

The row will not open unless a cube is connected and has said what it is called (`DeviceNameRules.renameRefusal`), and
it says which of those is missing rather than going quietly dead: renaming is a command that has to arrive somewhere,
so with nothing on the other end the app could only write down a name the hardware has never heard.

**What the device actually accepts.** The `0x15` entry in `docs/TimeFlip2 BLE Protocol v4.3.md`: `0xZZ … 0xZZ - name (18 symbols MAX. ASCII coding)`. Both limits are the device's, not choices this app made. The app adds one restriction of its own on top: control characters are excluded as well, leaving printable ASCII `0x20`-`0x7E`, since a tab or a NUL in a name that appears in every nearby device's scan list is a rendering problem for no gain. Note `0x2A00` reads up to 20 bytes, so only the *write* is capped at 18.

**Where the 18-character limit is enforced, and why in more than one place.** `DeviceNameRules.maximumLength` owns the number, and `DeviceCommandRules.setName` reads it, so the field and the bytes cannot come to disagree.

- *While typing*, the field truncates at 18. What is on screen is what will be written.
- *At submit*, the length is **checked** rather than truncated. From the field that is unreachable, which is the point: it stands between the device and a paste that outruns the truncation, or any later caller that does not come through this field.
- *At the write*, `setDeviceName` refuses over-18 and non-ASCII by returning false.

Characters are deliberately **not** filtered as they are typed. An emoji that vanished on the keystroke reads as a broken keyboard, with nothing to say why. It is left visible, refused at submit, and the alert names the reason -- and **the field stays open with the text still in it**, so a rejected name can be fixed rather than retyped from the context menu.

**What the refusal alerts must say**, all three parts required rather than stylistic:

1. That the **TimeFlip** cannot store the name, naming the device rather than the app.
2. That this is TimeFlip's limit, "not something this app has decided". A limit with no owner reads as the app being fussy, and leaves the user thinking some other app would allow an emoji. The attribution is also simply true: the vendor's own spec defines the field, and a name outside it cannot reach the device at all.
3. What **will** work -- up to 18 characters of letters, numbers, spaces and ordinary punctuation. Being told a name is wrong without being told what is right is guessing at an invisible rule.

A failed *write* is deliberately excluded from all of that: the device not answering is a different problem from a name it cannot hold, and quoting the character rules at a connection fault sends the user looking in the wrong place. `DeviceNameRulesTests` asserts each of these.

**What is pinned without a cube, and what is not.** `RenamingTheCubeReachesItFirstTests` drives the Name row against a real database and a radio with nothing on it, which is every path that must leave `device_name` alone: a name the cube cannot hold never reaching the radio, a name no cube took never being written down, the row going back to what is stored, and the reported-name rule refusing exactly the stale read. What no hermetic test can reach is a cube that takes the write, so the other half -- the row following a `0x15` the cube accepted, and the cube still being found on the next launch -- is `Tests/Scripted/66-device-rename.sh`.

The name is written down only once the cube has taken the write -- which, `0x15` having no reply of its own, is the whole of the evidence available. A write the cube would not take leaves both the Device tab and `device_name` saying what it still answers to, which matters beyond cosmetics: `device_name` is what the scan filter matches a renamed cube on, so a name the device never took would be a name nothing could be found by.

**The note for the device checklists is spent**, and it is worth recording why. The archive's rename needed
`act_cgevent_context_menu_pick`, because a SwiftUI `.contextMenu` is invisible to accessibility -- it reports zero
menus and `AXShowMenu` opens nothing. Clicking the name needs none of that: `66-device-rename` presses `device-name`
by identifier, writes `device-name-field` and posts Return, which is the same three lines `04-categories` renames a
category with.

### Confirmation, which the device makes impossible

**The check that has to run on hardware is `66-device-rename`.** The archive's equivalent was
`Archive/Tests/Bench/09b-device-rename-checklist.md`, last run against the cube on 2026-08-02, and what that run
verified is what the new one verifies: the part whose failure mode is losing the cube entirely, a renamed device still
being found on the next launch by the remembered `device_name` rather than by the vendor default.

**A rename cannot be confirmed at the time it is made, and the app says so instead of pretending otherwise.** There is no acknowledgement for `0x15` and no useful read-back within the session, both measured (see the note below), so `DeviceCommandRules.readBack(for:)` answers `nil` for it deliberately and the log row reads *the cube took the write; nothing can read this command back*. `peripheralDidUpdateName(_:)` is implemented and reports the GAP name a second or two into the *following* connection, which is the nearest thing to a confirmation there is; it reaches the app as `BluetoothRadio.onDeviceName` and is also what notices a cube renamed in the vendor's app.

**What the rebuild does differently from the archive is what it does with that report.** The archive adopted the reported name and had `AppState.shouldAdoptReportedName` to stop a first pairing taking a stale one; this app asks `DevicePairingRules.adoption`, which refuses exactly one value -- the name it renamed the cube *away from*, sitting in `previous_name` -- because macOS is a connection behind rather than the cube having changed its mind. So the tab and `device_name` keep the new name across reconnects instead of flickering back to the old one and forward again a connection later. The case that rule gets wrong is a second cube called exactly what this one was called before its last rename, which is written up at the rule.

`DeviceNameRules.renameLagNotice` is what is said at the moment of the rename: the cube has the name, the Bluetooth scan will go on showing the vendor default for ever, and macOS itself may report the old name until it next connects. It is an alert rather than the archive's caption on the tab, since nothing on the tab disagrees any more and a caption would need a flag saying whether it still applied.

(Note: the four findings below are what shaped the feature, all confirmed against the vendor spec and the hardware. They are kept because each one contradicts something this file previously asserted, and the corrections are worth more than the space:

**There is no usable read-back within the session that renamed the device, despite `0x2A00` being readable.** Measured on the hardware 2026-08-01: after a rename the app polled `TimeFlipDevice.deviceName` (which is `CBPeripheral.name`, the platform's own reading of `0x2A00`) **120 times over 30 seconds** and it never moved off the previous name. The value refreshes only when CoreBluetooth next connects and re-reads GAP, so it is connection-gated, not time-gated: no wait, however long, will see the change from within the same connection.

**The next connection does report it, and does so actively.** `peripheralDidUpdateName(_:)` fires about two seconds into the following connection, on all three of three renames tested. An earlier version of this note said it had "never fired once" -- that was concluded from the 30-second poll alone, which by definition could not observe a callback that only arrives after a reconnect. It is wired up and is what corrects the name a first pairing adopts from the stale cache.

So a rename gets **no confirmation at all** at the time it is made. The device never updates the command result characteristic for `0x15`, and `performCommand`'s check does not notice because a stale response from an unrelated command is neither one nor two bytes long and so skips validation entirely (see `docs/timeflip2-firmware-observations.md`, finding 2). Everything the app needs the name for -- the stored `device_name`, the Device tab, and the scan filter -- is updated from what was written rather than from a read. Forcing a disconnect/reconnect purely to refresh the cached value was considered and rejected: it costs a session drop, a re-login and a history re-sync to learn something already known.

Note this cuts against an earlier claim in this file that the name "has a real read-back, unlike LED brightness and blink interval". Readable in the GATT sense, yes; useful for confirming a write you just made, no.

**The displayed name now comes from the device.** It used to be a literal: `ApplicationDelegate` called `appState.confirmConnected(name: "TimeFlip", uuid: nil)` with the string spelled out in the source, so the Device tab read `TimeFlip` no matter what the cube was called, while the scan showed `TimeFlip v2.0` from `peripheral.name`. That call now passes `device?.deviceName`, so the tab, the in-memory state and `device_name` all agree with the cube (fixed 2026-08-01, confirmed live).

**18 ASCII characters, and the two limits differ.** The spec caps the `0x15` write at 18 symbols, ASCII only, while `0x2A00` reads up to 20. `setDeviceName` enforces the write limit by returning false, so an over-long or non-ASCII name would fail with only a debug line to show for it. Validate in the rename UI, not just at the BLE call.

**A renamed cube disappears from the scan, and that loses it on the very next launch.** Reconnecting is a **scan**, not a lookup of the stored `device_uuid`: `connect()` calls `scanAndConnect()`, and nothing in `TimeFlipBLEDevice` ever calls `retrievePeripherals(withIdentifiers:)`. The filter is `serviceMatches || nameMatches`, and the code's own comment records that the service UUID is **not** reliably advertised by this hardware, so the name match is in practice the only thing that finds the cube.

An earlier version of this note claimed the opposite -- that a rename was "harmless while the device stays paired, because reconnects go straight to the stored uuid". That was wrong, and it is why the scan work was filed as later rather than as a prerequisite. Renaming a cube to "Hazza" on 2026-08-01 made every reconnect time out from the next launch onwards; the log shows `connect begin`, `connect radio powered`, and then nothing. **Fixed** by `DeviceNameRules.matchesKnownDevice` in the archive, and in this app by `DeviceScanRules.isEligible`, which matches the vendor default, `device_name.name` and `device_name.previous_name` -- all three read from the table at the moment a scan or a reach starts rather than held anywhere.

The **All Devices** tick box (`scanAllDevices`, `TimeFlipSettingsView`) turns the filter off entirely and remains the manual way back if a cube is ever renamed by something other than this app -- but it is a backstop now, not the recovery path, and it was never reachable while `isPaired` was true anyway, since that state shows Forget/Reset instead of Scan.

One useful interaction: `0xFE` (reset task info) deliberately leaves the name untouched, so only a full `0xFF` factory reset clears it -- which is why `0xFE` touches neither row and `0xFF` clears both. The device-test runner's end-of-run factory reset therefore returns the cube to the vendor name and empties `device_name` with it, leaving nothing to repair afterwards.

**The firmware is inconsistent with itself about the name, and the spec does not mention it.** The `0x15` entry in `docs/TimeFlip2 BLE Protocol v4.3.md` is two lines -- a length byte and "18 symbols MAX. ASCII coding" -- and says nothing about when a rename takes effect or where it shows. What the hardware actually does, all measured on 2026-08-01:

- The GAP Device Name (`0x2A00`, what `CBPeripheral.name` reports) **does** change.
- The advertised local name **does not**: a cube whose GAP name read "Hazza cuber" was still advertising `TimeFlip v2.0`, across three successive renames.
- The change is not observable until the central reconnects, at which point CoreBluetooth notices it and fires `peripheralDidUpdateName(_:)`.

The two names disagreeing is what made a renamed cube unfindable, and the advertised name never changing is what makes it findable again, so both halves matter. Whether the cube applies a rename immediately or defers it is **not determinable from macOS**, since the host only re-reads GAP on connect; answering that needs a second central with no cache of this device.)

## Report

- A **Report** tab showing what each category took over a chosen span of days.
- Two calendars across the top: a start and an end. The end is **optional** -- a start on its own reports that single day, which is the common case in one click.
- The end can never precede the start, and neither can be in the future: this is a time recorder, not a time planner, so a future date would only ever answer "nothing tracked", which is indistinguishable from a real day on which nothing was. Both are enforced by what the calendars will let you pick rather than by refusing a selection afterwards, so there is no error state to report.
- A **day** here is the app's own day, `daily_reset_time` to the same time next day, not a calendar midnight. That is the window `DayWindow` defines and `DayTotal` measures the menu bar over, so a one-day report shows exactly what the menu bar showed that day.
- Totals come from `time_entry`, longest first. Spans straddling either end of the range are **clipped** to it, which is what makes two adjacent reports add up to the report over both -- an overnight segment would otherwise count in full on both of the days it touches.
- `Unassigned` is included, unlike the category lists, which start at `category_id` 1. Time on a face with no category of its own was still time spent, and dropping it would leave a report that quietly fails to add up to the day.
- Durations follow the existing **Show seconds in the menu bar** setting, so a span never reads one way in the menu bar and another way here. That setting also earns its keep on this screen: at `H:MM` every total under a minute reads `0:00`, indistinguishable from a category that was opened and left.

(Note: built as `ReportPane`, `ReportCalendar`, `ReportCalendarGrid`, `ReportCalendarMetrics`, `ReportRangeRules` and `TimeEntryStore.totals`. Verified against the device database, not only by unit test: a 5--6 Aug range rendered Unassigned 4:55, Break 3:54 and Meeting 1:57, matching the same clipped sums computed directly from `test.sqlite`.

The calendars are **drawn by this app rather than taken from the system**, which is a maintenance cost worth knowing about. Two requirements forced it, both established by measurement: the selected span is drawn bold and tinted across both calendars, and neither SwiftUI's `DatePicker` nor AppKit's `NSDatePicker` exposes any hook for styling an individual day cell; and the month arrows stop at the last month holding a selectable day, where a bare `NSDatePicker` with `minDate`/`maxDate` set directly still paged into a fully greyed-out month (measured 2026-08-08). A date bound governs which days can be *selected*, not which month is *displayed*. Don't revisit either without new evidence that the platform has changed.

What is missing, in dependency order rather than priority:

- **Grouping by project** -- see [Projects](#projects), which calls for exactly this. Nothing in the report references `project_id` today.
- **Cost totals** -- see [Cost time entry](#cost-time-entry). `total_cost` is written by nobody and reads zero on every row, so a cost column would be a column of zeros.
- **Export.** There is no way to get a report out of the app: no CSV, no copy, no print. Likely the first thing wanted once the numbers are trusted.
- **Arrow-key navigation inside the calendars.** Days are focusable and activate with space or return, but the system picker's arrow-key movement was not reimplemented. This is the one thing that got *worse* in leaving the native control.
- **No maximum cell size.** The calendars span the window, and a cell is square with the grid always six weeks, so a very wide window makes them tall as well as wide and squeezes the totals beneath. A cap is a small change if it ever bites.)

## Manual mode

**Now called "timing by hand", and it is no longer a mode.** The three dated sub-sections below are the record of how
it got there, newest first: it began as a `ManualMode` that could be switched mid-launch, became a `LaunchMode` fixed
at startup, and is now derived from `setting.paired` at the point of use with nothing holding it at all. Read
[The pairing decides again](#the-pairing-decides-again-2026-08-29) for where it landed; the two below it are why.

**[Implemented as a virtual device](#implemented-as-a-virtual-device) describes the previous implementation**, which
used a `MockTimeFlipDevice` swapped in behind the app's device protocol. The rebuild has no mock device and no
substitution: with nothing paired the app simply writes `device_event` rows itself, on faces 13 and 14 in rotation
(`ManualTimerRules`) rather than the single face 13 that table describes. The table is kept for the decisions in it,
several of which survived the rewrite -- one face was not enough, and why, is the clearest of them.

The cube gets left at work, or at home. The app should still be usable on those days rather than being dead weight until the device is back in range.

- After the app fails to reach a paired device at startup, it stops trying and asks whether to switch to manual mode, rather than going on retrying silently.
- In manual mode the user drives the timing from the app itself -- picking the category and starting/stopping it -- instead of by flipping a cube that isn't there.
- Manual mode is a state the app is in, not an unpairing: `paired` stays true and the device is still the user's device, so returning to it must not mean pairing again.
- **A launch with nothing paired starts here, and is not asked about it** (2026-08-11). The offer settles "your cube isn't answering -- keep trying, or time it yourself?", and with nothing paired there is no such question: no device was expected, no scan has failed, and there is nothing to retry. Asking anyway asks somebody who has never owned a cube to decide about one. What it replaces is an app that sat inert until the user found the Device tab -- no timer, nothing recordable, a menu bar showing its own name -- which is the state a brand-new user starts in and the state anybody who forgets their device restarts into.
- **Scanning and pairing work from inside a session** (2026-08-11), which is what makes the bullet above more than a consolation prize: someone can use the app for weeks with no device, buy a cube, scan, click it, and be in device mode without so much as a relaunch. It is also the way back for a cube whose PIN changed underneath the app -- forget it, and the scan list appears in the same session.

### Entering and leaving it

**The offer is a startup thing only.** It belongs to the question "is the cube with me today?", which is answered once, when the app comes up, and never again in that session.

**The decision is made on the scan.** One attempt is: scan everything advertising, build the list of eligible devices, and try to log in to each until one lets the app in or the list runs out. Eligibility is a name test, against the vendor default (substring) and both names in `device_name`, current and previous (exact). Two outcomes reach the same dialog:

1. **No eligible device is seen at all.** The cube is somewhere else.
2. **Eligible devices are seen but none accepts this app's PIN.** Every one is tried before the dialog appears.

The message is the same for both, because from the user's side they are the same situation: *"Unable to find your device"*, with **Rescan**, **Time by Hand** and **Quit** under it. (The heading read *"retry or switch to manual mode"* until the reversal recorded below took the switching out of the second button; the button names are the third set, see 2026-09-02.)

**Trying every candidate is not a nicety, it is the fix for a real defect.** The upstream driver (`23fe40e`) stopped the scan and connected the instant any peripheral matched on name, then logged in once. In an office where several people have TimeFlips, that means grabbing whichever colleague's cube advertised first, being refused because their PIN is not this app's, and giving up, with the user's own device sitting on the same desk untried. The `device_uuid` this app stores could have settled it and the connect path never read it: it was loaded at launch and used for nothing.

It now orders rather than filters the candidates. The paired uuid goes first, so the ordinary case costs one login attempt, but everything else is still tried behind it, because a cube that was re-paired, reset, or first paired on another Mac no longer carries that uuid and is still the user's own device. Filtering on it would trade this bug for a worse one.

- **One scan, then ask.** There is no attempt threshold, and there used to be: a `manual_mode` setting counting failures before the dialog, seeded to 3. It bought nothing. Every round is the same scan over the same airspace a few seconds later, so three of them find the same nothing three times, and the whole time the user is watching an app that appears to be doing something about it. Asking after one is honest about what the app knows, and the cost of being wrong is a click.
- **Rescan** runs the whole thing again from the scan. Fail again and the same dialog comes back. That loop has no limit: it repeats until the device answers or the user takes one of the other two. Rescanning is the same wait the threshold used to impose, with the difference that the user chose it.
- **Any successful connect ends the question for the session.** The app is in device mode from then on, and a connection that drops later behaves exactly as it does today: retry on the capped backoff, indefinitely, with no dialog. Losing the cube mid-session is a different situation from not having it, and the user has already told us which one they are in.
- **Choosing Time by Hand stops the app looking, for that launch, and hands it the clock.** It makes no further connection attempt *of its own* from any path, and the app is its own clock from that moment. One per-launch flag carries both halves; see 2026-09-02.
- **Choosing Quit ends the process and decides nothing.** Nothing is written and no flag is set, so the next launch asks the same question. It is here because the other two both commit to something and a cube left in the other room wants neither.

That rule is what makes the mode safe rather than clever, and it settles a question this section previously listed as open. Auto-exit on the next successful connect was the obvious answer and is a trap: the cube is sitting in a bag in the next room, drifts into range for a few seconds, and silently pulls the user out of manual mode mid-segment. An app that never looks cannot be surprised.

**What was rejected is the app looking, not the user.** The rule above used to be written as "final for that launch", with quitting named as the only way out, and that overshot: a person clicking a device in a scan list is the opposite of a mode changing under them, and the same sentence that keeps a cube in a bag from grabbing the session was also stopping somebody who had just bought one from using it. So the mode ended two ways, both of them acts: pair a device, or quit and start again. Nothing automatic was in either list. The cost this section used to accept -- returning to the cube means a relaunch -- was no longer charged.

Manual mode is still per-launch state, held in memory and nowhere else. There is no `setting` row for it at all, which removes the obvious place to put one by mistake.

### The offer switches the launch again (2026-09-02)

**The second button hands the clock back, and there is a third.** *Time by Hand* stops this launch reaching for the
cube and makes the app its own clock, in one act. *Quit* is new. The two answers before it both committed to
something -- wait, or give up -- and somebody who has realised the cube is in the other room wants neither; their way
out was dismissing the dialog and quitting from the menu bar, which is answering a question they came here to refuse.

**What it fixes was reported from use.** Somebody chose to work without the cube and found every category on the Faces
tab refusing to be clicked. The answer settled the reconnect loop and nothing else, so the app had taken the cube away
and given nothing back. Choosing to get on without the device and then not being allowed to is the one outcome the
question should not be able to produce, and it is what the 2026-08-23 reversal below cost without meaning to.

**Why the switching is safe now, having been removed twice.** Both earlier versions moved a value: a mode was set and
every surface had to be told, and the menu bar was the one that was not, its tick only running while something is
being timed. Nothing holds a mode here. `isManualMode` is
`ManualTimerRules.isManualMode(isCubePaired:hasGivenUpOnCube:)` -- one derivation, two inputs, both read at the point
of use -- so every surface answers the current question the next time it asks and there is no list to notify. The two
views that cannot ask on their own get a redraw, which is not a second source of truth: the menu bar for the tick that
does not run in this state, and the Faces tab for the flip that cannot arrive.

**`hasStoppedLooking` became `hasGivenUpOnCube`.** One flag with two consequences rather than two facts: the loop
arranges nothing further, and the app is its own clock. The old name was accurate while it did only the first and
would now describe half of what it does. The pairing is untouched throughout -- nothing writes `paired` -- so the cube
is still on record, `Rescan` is still available on a later launch, and forgetting the device stays a separate act with
a different meaning.

**A dev build presented the `config.json` PIN and no other stored one**, which is what made this testable between 2026-09-02 and 2026-09-04; the developer flag is gone and both stores are candidates again, so making a cube refuse means breaking both (`Tests/Methods.md` Method 16). A PIN
typed into the file to make a cube refuse used to be refused and then followed by the Keychain's real one, measured as
`Refused, and there is another PIN to try` then `PIN accepted` (2026-09-02 19:47): the wrong-PIN path could be set up,
reported as covered, and had reached a connected cube. `DeviceLoginRules.reconnectCandidates` still appends the vendor
default, so `000000` stays reachable and a battery change is still an ordinary Tuesday. `Tests/Methods.md` Method 16 is
the technique, including the trap that the cube must be on `123456`: on the default it logs in, rotates, and writes the
dev PIN back over the edit.

### The pairing decides again (2026-08-29)

**The mode is derived from `paired` at the point of use, and nothing holds it.** `LaunchMode` is gone. Pairing a cube
makes the app follow it from the next read on, forgetting or resetting one makes the app its own clock, and neither
needs a restart -- which is the cost the section below accepted and this one stops paying.

**Why it is safe this time, when the switching below was not.** That version moved a value: a mode was set, and every
surface had to be told it had moved, with nothing to catch the one that was not told. This version has nothing to move.
Timing by hand *is* being unpaired, so each surface answers the question when it asks it, and there is no second copy
to keep in step -- which is `CLAUDE.md`'s first rule applied to the thing that had been exempted from it. The one
surface that could still show a stale answer is the menu bar, which repaints on a tick that only runs while something
is being timed; pairing and forgetting call the same `onTimingChanged` funnel every other path uses, so it redraws. A
redraw is not a second source of truth.

**What the audit found underneath it.** `docs/state-audit.md` §1.1 lists four names for this fact and the trap that
two of its readers infer it a third way. The mode and the pairing were the same answer all along -- `LaunchMode.decided`
is `paired ? .device : .manual` and nothing moved it -- so the two could only ever differ by being read at different
*times*, which is exactly what the extra states in `DeviceInfoRules.connection` were describing. Deriving live deleted
three of its six lines, the `isManualMode` field on `DevicePane.Values`, and the `isManualMode` parameter on
`DeviceReconnectRules.shouldAttempt`, without replacing them with anything.

**What was genuinely per-launch is kept, under its own name.** Being told *Stop Looking* is not a mode: the cube is
still on record and the app has simply given up hunting for it this launch. That is `DeviceReconnector.hasStoppedLooking`
now, which is the fact the mode had been carrying on its behalf. It still ends only with the process, and the way to
timing by hand from there is to forget the device -- which now takes effect at once.

(**Half of that held and half of it did not**, and the section above says which: the fact is still per-launch and still
not the pairing, but it is `hasGivenUpOnCube` and it does make the app its own clock. Requiring a forget as well left a
launch that had given up hunting *and* refused to time by hand.)

### The switching was reversed (2026-08-23)

**A launch now decides its mode once and keeps it until it closes**, and the paragraph above is the thing that was undone. `LaunchMode` replaced `ManualMode`: an enum decided from `paired` at startup, with no setter. Pairing a cube mid-launch, forgetting one, resetting one, and answering the offer all leave the mode exactly as they found it.

**What it cost, stated plainly, because the paragraph above is right about the user experience.** Somebody who buys a cube and pairs it has to restart before the app will follow it. Somebody whose cube cannot be found has to forget it and restart before the app will time by hand. Both were one click before and are now a click and a relaunch.

**Why it was worth paying.** The switching gave "which mode is this launch in" two live sources -- `LaunchMode`, and the shape of a `TimingReadout.Reading` -- and nothing kept them in step. Every surface had to be told the mode had moved: the menu bar's colour, the Faces tab's click, the reconnect loop's gate, the Device tab's Connection row. Nothing caught the one that was not told, and one already had not been: the menu bar repaints on a tick that only runs while something is being timed, so a cube found while nothing was running left the item drawn for the old mode until something else happened to redraw it. The fix for that was a change hook, which is another thing to be kept in step. This is the fault `CLAUDE.md`'s first rule is about, in memory rather than in a table, and the reversal removes the possibility rather than adding a fourth place to catch it.

**What replaced the switch on screen is honesty about the mismatch**, in `DeviceInfoRules.connection`. A manual launch that has since paired a cube reads *"Connected, not used until restart"* -- not "Connected", which would describe a link the app has and a job it is not doing with it. A device launch whose cube has been forgotten reads *"Device gone, restart to time by hand"*, because the honest state otherwise reads exactly like the app being broken. Both name the restart, since in both the restart is the entire remedy and nothing on any tab is.

**While the dialog is up, the app makes no connection attempt at all.** It has stopped trying, and the next attempt is the user clicking Retry. Nothing else may start one behind an open dialog: not the backoff loop, not a wake from sleep.

This is `AppState.shouldAttemptConnection`: everything `shouldMaintainConnection` covers, minus the two states where the app has deliberately stopped, the offer being on screen and manual mode having been chosen. The three attempt sites read it (both wake-handler guards and the backoff retry), so all three stop at once.

**It is a second property rather than a change to `shouldMaintainConnection`, which the first draft of this section got wrong.** That property has a fourth reader, the drop handler, and there it asks a different question: a drop while it is false is reported as a *pairing failure*, on the reasoning that there was no pairing to reconnect to. Folding the manual-mode states into it would have made an attempt that failed just as the dialog went up report a pairing failure for a device that is perfectly well paired and merely out of range. The two questions read alike and are not the same one.

Implementation notes, from what the code does:

- **`reconnectAttempt` is a delay, not a count.** Its only job is picking the backoff in `scheduleReconnect()` (`min(2 * (attempt + 1), 30)` seconds). It was never given a second meaning: whether to offer manual mode is `ManualModeOffer`'s question, and all that survives of it is one flag, has this launch ever connected.
- **This is why the wake handler resets it**, which reads oddly until you know the field has one job. After a long sleep the loop may have climbed to the 30-second cap, and someone waking their Mac is presumably back beside the cube, so the reset puts the next attempt two seconds out instead of up to thirty. It is a latency reset, not a decision about how many times to try. The teardown-and-restart around it is there because CoreBluetooth can stop delivering scan results after a suspend without erroring, wedging the retry loop silently, so the handler distrusts the loop and rebuilds it rather than waiting on it.
- `scheduleReconnect()` was left alone in the end. The offer is raised where a failed attempt is already handled -- `startDeviceEvents` for a scan where every device refused the PIN, `handleReconnectFailure` for one that found nothing -- so the backoff never gets as far as being asked to stop. A deliberate teardown (`.cancelled`: a forget, a reset, a quit) returns before either, which matters now the first failure asks: without it, pressing Forget Device would raise the dialog.
- Nothing is offered when the app is not paired: there is no device to be out of range of, and connecting is already gated on `paired`.

(Note: this note and the table under it describe the **previous** implementation; the current app has no virtual device -- see the heading above. The mechanism there was a virtual device, `MockTimeFlipDevice` itself, driven by the Faces tab instead of by a test, through the same `TimeFlipSessionManaging` conformance and event pipeline `MockEventHTTPServer`'s `/flip` endpoint already proves end to end for test automation. It answers the central schema question -- a manual segment has no `device_event`, and `time_entry` requires one (`time_entry.device_event_id` is `NOT NULL REFERENCES device_event(device_event_id)`, carrying `UN1_time_entry`, a `UNIQUE` index) -- almost without schema change: a virtual flip just **is** a `device_event`, converted by the same `AppDataStore.convertEligibleEvents` a real one is. The exception is face 13, which needed the `device_face` `CHECK` widened and a `face` row seeded -- see the table below. Two other mechanisms were surveyed and set aside; see the end of this note for what they were and why.

Double-counting, the other question a manual/real split usually has to answer, is separately settled, and not by any mechanism: **the device and manual mode are never used at once.** The cube is paused and locked before it is left behind, stays that way for the whole day it is not carried, and which one gets used is decided once, at the start of the day, by whether it is in the bag. A paused `device_event` row never converts to `time_entry` regardless of who left it that way (`AppDataStore.convertEligibleEvents`'s `paused = 0` filter applies unconditionally), so a cube sitting paused all day, even if bumped, produces nothing to overlap a manual entry with -- there is no reconciliation rule to write, because there is never a second set of rows describing the same span. Within a launch the app makes the overlap impossible rather than merely unlikely, and it still does now that a session can end without the app quitting: pairing from inside one runs `endManualSession()` *before* anything connects, which closes the open manual row and stands the virtual device down, so the two never write across each other. The ordering is the guarantee, and it is the same guarantee the old wording ("entered once and never left") was making by never letting the situation arise -- see the last row of the table below for the mechanisms that hold it. What the app still does not detect is the discipline itself, which is a different and larger claim: a cube left running at home while the user times manually at work would have its segments ingested on the next connect, overlapping in wall-clock time with the manual ones. No guard on the write would have caught that, since nothing is connected at the moment either row is written. It rests on the cube being paused and locked before it is left, as above.

### Implemented as a virtual device

**The previous implementation.** `MockTimeFlipDevice`, `ApplicationDelegate`, `AppState`, `ConnectionStatus` and
`MockEventHTTPServer` are all in `Archive/`; none of them exists in the current app. What carries forward is the
reasoning, and the two rows worth re-reading before touching this area are the face-number one (which the rebuild
answered differently) and the last one, on why a guard against writing in both modes at once was not needed.

Every row below was built, in the previous app. Kept in roughly dependency order, with each row's Decision saying what was actually done rather than what was planned -- several were built twice, and where the first attempt was wrong the row says so, since that is the part worth not repeating.

| Change | Why | Decision |
|---|---|---|
| A startup-only check that stops the retries and raises the retry-or-manual dialog | This is the entry point the spec calls for. Nothing ever stopped retrying | **Built**, and simpler than first built: no threshold and no `manual_mode` setting, just the first failure asking. `ManualModeOffer` is down to the has-ever-connected flag, `AppState.shouldAttemptConnection` is the gate the retry and wake paths read, and `ApplicationDelegate.offerManualMode()` runs the alert |
| `ApplicationDelegate.device` becomes a reassignable `var`, swapped to `MockTimeFlipDevice` on entering manual mode | This is the actual substitution the whole approach rests on | **Built**, but through `startManualSession()` rather than `startDeviceEvents()`. That path is connect-and-log-in and would have stamped `connection.last_connection` for a device never reached, synced LED and face colours to hardware that does not exist, and stood up `MockEventHTTPServer` on an ordinary user's machine. What manual mode needs is the ingestor and the event stream, nothing else. It does swap back, in `endManualSession()`, when a pairing succeeds -- which needed one thing the original swap did not have: the radio is now held in its own property (`bleDevice`) for the whole launch. Reassigning `device` used to drop it, `CBCentralManager` and all, because nothing else held a reference, and every discovery path reached it by casting `device` -- so in manual mode the scan button called a cast that failed and returned having done nothing |
| A manual-mode UI control that drives the virtual device directly: pick a category, start/stop | This is what "the user drives the timing from the app itself" (see the second bullet at the top of this section) actually means in code | **Built** on the Faces tab, which already had the two halves it needs: a device graphic and a list of categories to put on it. Clicking a category starts the clock on it; where the device graphic sits with a cube, manual mode draws the play/pause control alone, empty until something is picked. The artwork itself is not drawn -- there is no cube in this mode, so a picture of one would be reporting nothing. `ManualTimerRules` holds what it draws and when it is clickable. The icons report state rather than offering an action -- play showing means time is being recorded -- which is the opposite of a media player and deliberate: it sits where the category icon does and answers "am I on the clock?" |
| Which `device_face` a manual flip writes: **face 13**, one dedicated face that manual mode owns | `convertEligibleEvents` resolves category purely by joining `device_event.device_face` through `face` (`JOIN face f ON f.face_id = de.device_face`), so something has to land in that column | **Built.** A single face 13, not the 13-24 range this row used to weigh against borrowing a real face. One face is enough because manual mode times one thing at a time -- the category being tracked is whatever face 13 holds, rather than twelve standing mappings. It keeps the existing category-on-a-face machinery doing the resolution, and it does not tie a manual category to whatever the cube's own faces happen to be assigned to. It gets there from the Faces tab, which is also the answer to "whether it shows up": in manual mode that tab **is** face 13, and it is the only place the face is drawn |
| Widening the two face-ID bounds to admit 13 | Face 13 has to survive both a `CHECK` and a Swift validator that today stop at 12 | **Built**, and the two bounds are now two functions. `isValidFaceID` still stops at 12 and stays the one every BLE path uses (`TimeFlipHistoryParser.parse`, the `TimeFlipBLEDevice` notification handlers), so a frame claiming 13 is still a corrupt frame; `isValidStoredFaceID` admits 13 and guards the app's own side -- the `face` table writes, the Faces tab, the menu bar's category lookup. `device_event`'s `CHECK` went to 13 by the table rebuild in `003_device_event.sql`, applied to both databases on 2026-08-09 and confirmed with `scripts/compare-database-to-ddl.sh`; `face` row 13 is seeded like the other twelve |
| A new `ConnectionStatus` case for "connected, to the stand-in" | Today's enum has no state meaning "intentionally not trying to reach the paired device," and the UI needs to tell the two apart | **Built** as `ConnectionStatus.manual`, and it did more than tidy the readers. Manual mode had been a `@Published` flag beside the status, which is two answers to one question and lets them disagree -- and the disagreement that mattered was a manual session running while the status said `.connected`, the exact pair the dropped guard in the last row was proposed to catch. `AppState.isManualMode` is now derived (`connectionStatus == .manual`), so the two are cases of one enum and cannot coexist. `MenuBarLiveDisplay` lost a rule outright: `tearsDownOnDisconnect` existed only because manual mode reported `.disconnected` while running, and once the status is no longer a lie there is nothing to take an exception to -- `.manual` is an ordinary arm of `handleConnectionStatusChange`. `MenuBarClickRouter` and `DeviceTabRules` now take the status alone; `SettingsTabRules` still takes a `Bool`, never having asked about the connection in the first place, and feeding it a whole status would be more coupling, not less. The Device tab's Connection row reads "Manual mode, no device" rather than the "Disconnected" it used to. The audit this row warned about turned out to be the compiler's: every `switch` over the enum is exhaustive, so both of the two that existed had to answer for the new case before it would build |
| Guard `confirmConnected(name:uuid:)` (`Archive/TimeFlipApp/ApplicationDelegate.swift`) against a manual session's first synthetic event | A virtual device's first flip looks identical to a real device's first status report and would overwrite the real device's stored name | **Built**, and it needed no guard in the end. That call is reached only while `awaitingInitialStatus` is true, which `startDeviceEvents` sets and `startManualSession` deliberately does not -- so the trap is closed by the manual path never arming it, rather than by a condition at the call site that a later edit could get wrong. The virtual device is also configured not to emit an initial status at all |
| An in-memory "manual mode is on" flag, deliberately **not** persisted | Something has to model "don't try the real device again this launch" | **Built**, and it inverts what this row used to say. `AppState.isManualMode`, per-launch and written nowhere: persisting it would outlive the relaunch that is the only way out of the mode, stranding the user in it |
| How manual mode ends | The spec says ending needs to be at least as deliberate as entering | **Built**, and deliberate is exactly the test it has to pass: quit and start again, or pair a device from the Device tab. Nothing automatic ends it, because nothing automatic is looking. The second exit was added on 2026-08-11, when "quit and restart" turned out to be the only way a user who had just bought a cube could use it. See [Entering and leaving it](#entering-and-leaving-it) for why auto-exit on the next connect is still rejected |
| The virtual device must not invent segments, or hide the one it is timing | `MockTimeFlipDevice` was built for tests, where fabricated history is a feature and an unreported open segment is harmless. Manual mode is the first caller whose history reaches a **real** database | **Built** as two `Configuration` flags, both defaulting to the old behaviour so nothing else in the suite shifts. `seedsSampleHistory: false` stops the two invented segments being ingested as work the user never did. `reportsOpenSegment: true` makes a fetch end on the running segment, which is what a real dump does (`docs/timeflip.md` §5) and what this device has never done -- a standing parity gap. Without it a running segment lives only in memory until something closes it, and quitting is the documented way *out* of manual mode, so every session would lose whatever it was timing. Turning the default on is worth doing, separately, once the suite is looked at |
| What the menu bar **does** while in manual mode | The status item is split down the middle, and the right half's pause and lock have no device to act on | **Built.** The right half still pauses: there is a timer to stop, so it keeps its meaning even though the device the ordinary pause talks to is absent. It routes to the same path the Faces tab's play/pause uses, not to `onPauseToggle`, which ends in a device command and would be refused anyway -- so the two controls cannot disagree about what pausing means. Lock does not survive, having nothing to lock, which is why the pause fires immediately rather than waiting out the double-click interval: that wait exists only to let a second click upgrade to lock. A double-click is therefore two toggles, landing back where it started. The left half keeps the menu, which is where Quit lives, and that matters more here than anywhere else since quitting is the only way *out* of the mode. Two earlier attempts were removed on the way: the left half opening Settings (it put that single exit behind knowing which half to click) and a branch outranking the low-battery route (the offer only fires on a launch that never connected, so there is no battery reading to blink). `MenuBarClickRouter` carries the rules, out of the AppKit handler no test could call. The dropdown's own Pause item was left behind by all of this and caught up afterwards: it read `isConnected`, which manual mode is not, so the same gesture had a live trigger on the status item and a grey one in the menu directly above it. `MenuBarDropdownRules` now holds both items' titles and enabled states, out of `rebuildMenu()` for the same reason -- it builds real `NSMenuItem`s, which is how the two came to disagree with nothing failing. Lock stays disabled there: Pause survived manual mode because the thing it acts on moved into the app, and lock has no such half |
| Which tab Settings opens on while in manual mode | Manual timing is driven entirely from the Faces tab, and landing on whichever tab the window was last closed on puts the user a click away from the only thing they opened it for | **Built.** Always Faces, on every open and from the dropdown's Settings item too, not only the first open of a launch. `SettingsTabRules` holds it alongside the existing low-battery jump to Device, which it outranks; outside both cases it returns `nil` and the remembered tab stands, since moving a user's window under them is the worse default |
| How a manual session's last segment is closed | Every other segment in `device_event` is closed by the frame after it, and a manual session has no frame after its last one | **Built.** `AppDataStore.closeOpenManualSegment(endingAt:)`, called from `applicationWillTerminate`, finalises the open row on face 13 and sweeps it into a `time_entry`. Done straight against the database rather than by pausing the virtual device and refreshing history: that path is async and coalesces against a fetch already in flight, either of which loses the race with termination. The same call runs at launch with `endingAt: nil`, for a run that never reached the quit handler -- a crash or a force quit -- where the row keeps the duration it was last written with, since when it actually stopped is unknowable and a figure from the clock now would be invented. A cube's open row is deliberately untouched by both: that one is closed by the next frame, and finalising it here would freeze it at whatever it read at launch |
| What the menu bar **shows** while in manual mode | Today's UI reflects device state, and the menu bar read it so literally that manual mode showed a bare app name and nothing else: the display was gated on having reached a *cube* this session, and `enterManualMode` set `.disconnected`, which tore it down outright | **Built**, and the answer is that nothing changes -- a manual session shows the same category, icon, duration and colours a connected cube does, because its reading is as current as one gets. `MenuBarLiveDisplay` holds the questions that had been read straight off `isPaired`/`connectionStatus`: whether there is anything to draw, and whether it is current enough for the live colours. It held a third, whether a `.disconnected` should clear the display, which `ConnectionStatus.manual` later made unnecessary: the status manual mode reports is now its own case rather than a `.disconnected` the teardown had to be told to ignore |
| Which database a launch opened | It decides where every segment of the day lands, and the moment it is worth knowing is the moment you have forgotten which one you started under | **Removed, 2026-09-04.** The `TEST`/`PROD`/`DB?` tag was built, and then went with the developer flag it was drawn for: it occupied the one line the app has to say what it is doing, permanently, to answer a question that is asked once a session at most. `setting.db_type` still holds the answer, `require_test_database` is what stops a scripted run against the wrong file, and the Report tab's own figures are what say which database is in front of you |
| What the **Device tab** shows while in manual mode | Its fields are all device state -- battery, auto-pause, LED, lock -- and none of it exists for a virtual device | **Built**, and mostly already true: every device setting on that tab is gated on `!appState.isConnected`, so in manual mode they are all on show and all dead, which is the wanted answer. The exception was Forget Device and Reset Device, deliberately *not* gated that way so an out-of-range cube can still be forgotten. In manual mode that reasoning fails, because something answers: Reset is routed against the protocol rather than the BLE type (done so the mock is testable) so `0xFF` lands on the stand-in, is confirmed, and `forgetDevice(deviceWasWiped: true)` discards the real cube's stored name and uuid; Forget casts to the BLE type and returns `true` when the cast fails, so it reports success having sent nothing, clears the stored password and unpairs, leaving the cube holding a rotated PIN whose only copy has just been deleted. Both read as ordinary buttons and neither is recoverable without the device in hand. `DeviceTabRules.allowsPairingActions` switched them both off. **They stopped agreeing on 2026-08-11**, when Forget was rewritten to send nothing at all: with no device round trip left in it there is nothing for a stand-in to answer, and switching it off in manual mode was closing the escape hatch on the one state that needs it -- a cube whose PIN changed underneath the app, where forgetting is the only route back and manual mode is where the user has been put. It is also now how the scan list appears mid-session. So the one rule is two, `allowsForget` and `allowsReset`: Reset stays off in manual mode for the `0xFF` reason above, which is untouched. Neither is gated on being connected, which is the original point of the pair |
| (Optional) a guard refusing a manual write while `AppState.isConnected` is true | Would turn the never-both assumption into something the app checks | **Not needed, and dropped.** The state it guards against cannot occur: a manual write and a live connection cannot coexist, because the session is stood down before anything connects (`endManualSession()`, which also closes its open row) rather than running alongside the thing replacing it. That is held by three separate things, two of them built for other reasons. `AppState.shouldAttemptConnection` is false from the moment manual mode is chosen, and all three attempt sites read it, so no new connect can start. Of the two paths that can reach `.connected`, one is guarded by `connectionStatus == .reconnecting` and manual mode sets `.manual`, and the other is `confirmConnected`, reached only while `awaitingInitialStatus` is true, which `startManualSession` deliberately never sets -- so the only way to that status from a manual session is the deliberate pairing, which sets `awaitingInitialStatus` by going through `startDeviceEvents`, and reaches it *after* `endManualSession()` has already stood the virtual device down. A guard here would be checking for something none of those allow. The `ConnectionStatus.manual` row above later made it a fourth time impossible, and the only one of the four that is structural: manual mode and `.connected` are now cases of the same enum, so `isConnected` is false in manual mode by construction rather than by three audited paths agreeing |

Reused for free, not a row above: the virtual device's own `event_number` allocation. `MockTimeFlipDevice.allocateEventNumber()` already mints a fresh, non-colliding counter per session the same way it does for tests today, and `MockTimeFlipDevice.Configuration.latency` already defaults to `.instant` -- every call answers immediately, which is what a manual-mode session wants -- while tests opted into `.realistic(scale:)` explicitly where timing itself was under test (`Archive/TimeFlipAppTests/MockDeviceLatencyTests.swift`). Reusing the type as-is, rather than a new one alongside it, is what makes both of these free.

### What is still open

**Nothing, in the current app.** The two debts recorded here were both properties of the virtual device, and neither
survived the rewrite: there is no `MockTimeFlipDevice` to change a default on, and event numbers are no longer the
only thing separating the app's segments from a cube's. What replaced the second is a face test --
`DeviceEventRecorder.newestFromTheCube()` asks only for faces a cube can reach -- which is the same exclusion by a
clearer route.

It is covered on hardware now, by `Tests/Scripted/56-manual-mode.sh`, which is what the note here used to ask for: it
was written when none of this had run in the app even once.

### Options set aside

**Negative `event_number` rows in `device_event`.** The real device only ever produces positive numbers (`event_number` is `UInt32` end to end) and the column carries no `CHECK`, so a hand-written negative row cannot collide with a real one and needs no schema change; `convertEligibleEvents` never inspects the sign, so a finalized manual row would convert like a real one. Set aside for what it does not avoid: `latestRecordedEvent()` orders by `start_epoch` with no clause excluding a manual row, so one would become the "newest" row on record for as long as manual mode is active and force a full history re-stream on the next real reconnect. The chosen option turned out to have the same hazard by a different route -- a manual row's event number is seeded from the wall clock, so it dwarfs a cube's counter -- and it is fixed there by `latestRecordedEvent()` asking only for `device_face <= maxFaceID`. That it needed fixing at all is the point: it was a required change either way, not a nice-to-have -- and it would still need face 13 and the bounds widening that go with it, without gaining the virtual device's reuse of an already-built, already-proven pipeline.

**A separate `manual_time_entry` table**, merged with `time_entry` only at the read layer. Manual-vs-real would have been structural, which table a row is in, rather than a sign convention, and could never collide with any of `device_event`'s ordering machinery, since it would never touch that table at all. Set aside as the most code of the three: three read paths (`loadCategoryTotals`, `loadTimeEntries`, `DailyCategoryTotals.seedFromHistory`) would need a second source merged in, an open manual segment would have no physical device to persist it if the app crashed, and it forecloses reusing a virtual device's protocol substitutability later -- exactly what the chosen option leans on.)
