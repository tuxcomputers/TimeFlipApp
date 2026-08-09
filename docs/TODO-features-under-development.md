# Feature under development

- [x] Categories
- [x] Faces
- [x] Time logs
- [ ] Calendar sync
- [ ] Sync to TimeFlip cloud
- [ ] Projects
- [ ] Cost time entry
- [x] Device rename
- [x] Report
- [ ] Manual mode

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

Built in PR #43. `AppDataStore.createTimeEntriesForFinalisedEvents` runs at the end of every `recordDeviceEvent`, so an entry appears as the following flip closes a segment out. `sweepTimeEntries(trigger:)` is the wider pass that drops the `processed` condition to find rows wrongly marked done, triggered on launch, on history ingest, and before a face changes category -- before, so the entry can still resolve the face-to-category link as it was when the time was spent. `UN1_time_entry` makes one entry per `device_event` a constraint rather than a convention. See [Operation Spec § 3](operation-spec.md).

Segments shorter than `blip_time` get no entry and are marked `processed`, which is the cube being turned past a face rather than time spent on it.

(Note: one bullet above is **not** built and has been split out as [Cost time entry](#cost-time-entry) rather than left as a footnote here. `total_cost` is never calculated from the category's `cost`: the insert omits the column and takes the schema's `DEFAULT 0`, so every entry so far reads zero. Everything else in this section is built.)

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

(Note: `project` (`006_project.sql`) is currently id/name only -- "for now", per its own comment -- and `category.project_id` already links many categories to one project, so that part of the association is already schema-supported; each category's own `cost` is what rolls up under the project. What's missing: any project create/manage UI at all (no `Project`-named view exists anywhere in `Sources/`), and any reporting query that groups by `project_id` -- the [Report](#report) tab groups by category only and doesn't reference `project` at all. Note that `ReportSettingsView.swift`, despite its name, is the **App** tab and never was the report; it took the name first, which is why the tab enum's `.report` case had to be renamed `.app` when the real one arrived.)

## Cost time entry

- A category's `cost` is a rate **per hour**, not a flat charge per entry. So a `time_entry`'s `total_cost` is that rate applied to its `duration_seconds`: `cost * duration_seconds / 3600`, both sides in whole cents.
- It is captured, not looked up later: changing a category's `cost` afterwards must leave every existing `time_entry` exactly as it was, the same way `category_id` is captured rather than resolved at read time.
- Reporting can total cost, per category and (with Projects) per project.

(Note: the column exists and is written by nobody. `time_entry.total_cost` is `INTEGER NOT NULL DEFAULT 0` and the insert in `AppDataStore.convertEligibleEvents` omits it, so every entry created so far reads zero -- this was split out of Time logs, whose spec called for it, rather than left as a footnote there. `category.cost` is likewise `INTEGER NOT NULL DEFAULT 0` and there is no UI anywhere that sets it, so the input side is missing too.

Both columns are **whole cents**, per [Database Design](database-design.md) (`250` = \$2.50), so money never touches a float, and `cost` is a rate per hour. That leaves one thing open:

**How the result rounds.** `cost * duration_seconds / 3600` will rarely land on a whole cent, and at these durations the remainder is most of the value: a two-minute segment at \$60/hour is 200 cents exactly, but at \$55/hour it is 183.33. Rounding to the nearest cent per row is the obvious rule and is what to implement absent a reason otherwise. Worth writing down rather than leaving to the first implementation, because a report that sums the stored `total_cost` values and one that recomputes from the durations will otherwise disagree by a few cents with neither being wrong, and the fix then has to pick a winner retrospectively. The safe convention: **the stored value is the price**, and anything reporting on it sums rows rather than re-deriving them.

No currency column exists anywhere, which is fine for one user with one currency and worth knowing before a second one turns up.)

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

## Report

- A **Report** tab showing what each category took over a chosen span of days.
- Two calendars across the top: a start and an end. The end is **optional** -- a start on its own reports that single day, which is the common case in one click.
- The end can never precede the start, and neither can be in the future: this is a time recorder, not a time planner, so a future date would only ever answer "nothing tracked", which is indistinguishable from a real day on which nothing was. Both are enforced by what the calendars will let you pick rather than by refusing a selection afterwards, so there is no error state to report.
- A **day** here is the app's own day, `daily_reset_time` to the same time next day, not a calendar midnight. That is the window `DailyCategoryTotals` measures the menu bar over, so a one-day report shows exactly what the menu bar showed that day.
- Totals come from `time_entry`, longest first. Spans straddling either end of the range are **clipped** to it, which is what makes two adjacent reports add up to the report over both -- an overnight segment would otherwise count in full on both of the days it touches.
- `Unassigned` is included, unlike `AppDataStore.loadCategories()`, which starts at `category_id` 1. Time on a face with no category of its own was still time spent, and dropping it would leave a report that quietly fails to add up to the day.
- Durations follow the existing **Show seconds in the menu bar** setting, so a span never reads one way in the menu bar and another way here. That setting also earns its keep on this screen: at `H:MM` every total under a minute reads `0:00`, indistinguishable from a category that was opened and left.

(Note: built on `feature/reportTab` -- `ReportView`, `ReportDateRange`, `ReportCalendarView`, `ReportCalendarGrid`, `ReportCalendarMetrics`, and `AppDataStore.loadCategoryTotals(from:to:)`. Verified against the device database, not only by unit test: a 5--6 Aug range rendered Unassigned 4:55, Break 3:54 and Meeting 1:57, matching the same clipped sums computed directly from `test.sqlite`.

The calendars are **drawn by this app rather than taken from the system**, which is a maintenance cost worth knowing about. Two requirements forced it, both established by measurement: the selected span is drawn bold and tinted across both calendars, and neither SwiftUI's `DatePicker` nor AppKit's `NSDatePicker` exposes any hook for styling an individual day cell; and the month arrows stop at the last month holding a selectable day, where a bare `NSDatePicker` with `minDate`/`maxDate` set directly still paged into a fully greyed-out month (measured 2026-08-08). A date bound governs which days can be *selected*, not which month is *displayed*. Don't revisit either without new evidence that the platform has changed.

What is missing, in dependency order rather than priority:

- **Grouping by project** -- see [Projects](#projects), which calls for exactly this. Nothing in the report references `project_id` today.
- **Cost totals** -- see [Cost time entry](#cost-time-entry). `total_cost` is written by nobody and reads zero on every row, so a cost column would be a column of zeros.
- **Export.** There is no way to get a report out of the app: no CSV, no copy, no print. Likely the first thing wanted once the numbers are trusted.
- **Arrow-key navigation inside the calendars.** Days are focusable and activate with space or return, but the system picker's arrow-key movement was not reimplemented. This is the one thing that got *worse* in leaving the native control.
- **No maximum cell size.** The calendars span the window, and a cell is square with the grid always six weeks, so a very wide window makes them tall as well as wide and squeezes the totals beneath. A cap is a small change if it ever bites.)

## Manual mode

The cube gets left at work, or at home. The app should still be usable on those days rather than being dead weight until the device is back in range.

- After the app fails to reach a paired device at startup, it stops trying and asks whether to switch to manual mode, rather than going on retrying silently.
- In manual mode the user drives the timing from the app itself -- picking the category and starting/stopping it -- instead of by flipping a cube that isn't there.
- Manual mode is a state the app is in, not an unpairing: `paired` stays true and the device is still the user's device, so returning to it must not mean pairing again.

### Entering and leaving it

**The offer is a startup thing only.** It belongs to the question "is the cube with me today?", which is answered once, when the app comes up, and never again in that session.

- At startup the app tries `manual_mode.prompt_after_attempts` times (seeded to 3). If none of them reach the device it **stops trying** and puts up a dialog: the device is not in range, retry or switch to manual mode.
- **Retry** resets the attempt count and tries that many times again. Fail again and the same dialog comes back. That loop has no limit: it repeats until the device answers or the user picks manual mode.
- **Any successful connect ends the question for the session.** The app is in device mode from then on, and a connection that drops later behaves exactly as it does today: retry on the capped backoff, indefinitely, with no dialog. Losing the cube mid-session is a different situation from not having it, and the user has already told us which one they are in.
- **Choosing manual mode is final for that launch.** The app makes no further connection attempt of any kind, so the mode ends the only way it can: quit and start the app again.

That last rule is what makes the mode safe rather than clever, and it settles a question this section previously listed as open. Auto-exit on the next successful connect was the obvious answer and is a trap: the cube is sitting in a bag in the next room, drifts into range for a few seconds, and silently pulls the user out of manual mode mid-segment. An app that never looks cannot be surprised. The cost is that returning to the cube means a relaunch, which is a fair price for a decision the user makes about once a day, and a visible one, unlike a mode that changes under them.

It also decides what **must not** be persisted. Manual mode is per-launch state, held in memory and nowhere else. Writing it to the `manual_mode` row would survive the relaunch that is the only way out of it, leaving a user who had to restart to get their cube back still in manual mode with no exit at all.

Implementation notes, from what the code does today:

- `reconnectAttempt` alone cannot express "startup only": the same counter is reset and reused by post-drop reconnects, the system-wake path (`ApplicationDelegate.swift:583`) and the factory-reset confirm loop. The prompt needs "has this launch ever connected?" alongside it, and only the never-connected case counts the attempts against the threshold.
- `scheduleReconnect()` currently always schedules another attempt. The startup path needs it to stop at the threshold and hand off to the dialog instead, which is the one behavioural change to an existing method rather than an addition beside it.
- Nothing is offered when the app is not paired: there is no device to be out of range of, and connecting is already gated on `paired`.
- Decide what the system-wake handler does when the dialog is up and the app has never connected. It resets the counter and reconnects today, which would start a second attempt run behind an open dialog.

(Note: nothing here is built. The mechanism is settled: a virtual device, `MockTimeFlipDevice` itself, driven by a manual-mode UI control instead of a test, through the same `TimeFlipSessionManaging` conformance and event pipeline `MockEventHTTPServer`'s `/flip` endpoint already proves end to end for test automation. It answers the central schema question -- a manual segment has no `device_event`, and `time_entry` requires one (`time_entry.device_event_id` is `NOT NULL REFERENCES device_event(device_event_id)`, carrying `UN1_time_entry`, a `UNIQUE` index) -- with no schema change at all: a virtual flip just is a `device_event`, converted by the same `AppDataStore.convertEligibleEvents` a real one is. Two other mechanisms were surveyed and set aside; see the end of this note for what they were and why.

Double-counting, the other question a manual/real split usually has to answer, is separately settled, and not by any mechanism: **the device and manual mode are never used at once.** The cube is paused and locked before it is left behind, stays that way for the whole day it is not carried, and which one gets used is decided once, at the start of the day, by whether it is in the bag. A paused `device_event` row never converts to `time_entry` regardless of who left it that way (`AppDataStore.convertEligibleEvents`'s `paused = 0` filter applies unconditionally), so a cube sitting paused all day, even if bumped, produces nothing to overlap a manual entry with -- there is no reconciliation rule to write, because there is never a second set of rows describing the same span. The app does not itself detect or enforce the discipline this rests on; the optional backstop below is a cheap way to add one.

### Implementing it as a virtual device

In roughly dependency order:

| Change | Why | Decision |
|---|---|---|
| A startup-only threshold check on `reconnectAttempt`, stopping the retries and raising the retry-or-manual dialog | This is the entry point the spec calls for. Nothing today compares the counter to anything, and nothing ever stops retrying | Decided, see [Entering and leaving it](#entering-and-leaving-it). The threshold itself is **done**: the `manual_mode` setting's `prompt_after_attempts`, seeded to 3 and clamped 1-20, read by `AppDataStore.loadManualModePromptAfterAttempts()`. Left to build: a "has this launch ever connected?" flag to scope it to startup, the stop in `scheduleReconnect()`, and the dialog with its retry loop |
| `ApplicationDelegate.device` becomes a reassignable `var`, swapped between `TimeFlipBLEDevice` and `MockTimeFlipDevice` on entering/leaving manual mode | This is the actual substitution the whole approach rests on | Swap via the existing `stopDeviceEvents()`/`startDeviceEvents()` pair, which already exist to rebind around it |
| A manual-mode UI control that drives the virtual device directly: pick a category, start/stop | This is what "the user drives the timing from the app itself" (see the second bullet at the top of this section) actually means in code | Not fleshed out. Reachability is proven (`MockEventHTTPServer`'s `/flip` already calls the same `TimeFlipMockControlling.flip(to:)`), but no UI exists -- where it lives, what it looks like, how a category is picked |
| Which `device_face` a manual flip writes: borrow whichever real face 1-12 already maps to the chosen category, or give manual mode its own 13-24 range with independent mappings | `convertEligibleEvents` resolves category purely by joining `device_event.device_face` through `face` (`JOIN face f ON f.face_id = de.device_face`), so something has to land in that column | Not fleshed out. Borrowing a face costs nothing but ties a manual category to whatever the cube's faces happen to be assigned to; a dedicated 13-24 range needs a real migration on `device_event.device_face`'s `CHECK (device_face BETWEEN 1 AND 12)` (SQLite has no `ALTER` for a `CHECK`, only a table rebuild) and its own separately-scoped face-ID range, since `TimeFlipConstants.maxFaceID`/`isValidFaceID` also validates a face byte parsed off a **real** BLE frame (`TimeFlipHistoryParser.swift:17`, `TimeFlipBLEDevice.swift:661,1483,1505`) and drives the real Faces tab and colour-sync loop (`AppState.swift:580`, `ApplicationDelegate.swift:964`) |
| A new `ConnectionStatus` case for "connected, to the stand-in" | Today's enum has no state meaning "intentionally not trying to reach the paired device," and the UI needs to tell the two apart | Not fleshed out. The case is not named, and every existing `switch` over `ConnectionStatus` needs auditing for it |
| Guard `confirmConnected(name:uuid:)` (`ApplicationDelegate.swift:1072`) against a manual session's first synthetic event | A virtual device's first flip looks identical to a real device's first status report and would overwrite the real device's stored name | Not fleshed out. The trap is pinned to the exact call site; the guard condition itself is not written |
| An in-memory "manual mode is on" flag, deliberately **not** persisted | Something has to model "don't try the real device again this launch" | Decided, and it inverts what this row used to say. Persisting it would outlive the relaunch that is the only way out of the mode, stranding the user in it. Per-launch state, held in memory, written nowhere |
| How manual mode ends | The spec says ending needs to be at least as deliberate as entering | Decided: quit and restart the app. Nothing else ends it, because nothing else is looking. See [Entering and leaving it](#entering-and-leaving-it) for why auto-exit on the next connect was rejected |
| What the menu bar (and Device tab) show while in manual mode | Today's UI reflects device state -- the current face, pause, battery, lock -- and none of it exists for a virtual device | Not fleshed out |
| (Optional) a guard refusing a manual write while `AppState.isConnected` is true | Turns the never-both assumption above from a routine into something the app actually checks | Not fleshed out, and depends on the `device_face` decision above for what counts as "outside range" -- but the *location* is decided: at the one call site that constructs a manual `device_event`-shaped row, not inside `TimeFlipConstants.isValidFaceID` or `TimeFlipHistoryParser.parse`. Both are pure and stateless today and already fully guard the real-BLE-frame path on their own regardless of any flag (`AppDataStore` has zero references to `AppState` anywhere in it, confirmed by grep), and `connectionStatus` is confirmed set to `.connected` (`ApplicationDelegate.swift:745`) *before* history backfill runs, so there is no timing gap to worry about at that call site |

Reused for free, not a row above: the virtual device's own `event_number` allocation. `MockTimeFlipDevice.allocateEventNumber()` already mints a fresh, non-colliding counter per session the same way it does for tests today, and `MockTimeFlipDevice.Configuration.latency` already defaults to `.instant` -- every call answers immediately, which is what a manual-mode session wants -- while tests opt into `.realistic(scale:)` explicitly where timing itself is under test (`Tests/TimeFlipAppTests/MockDeviceLatencyTests.swift`). Reusing the type as-is, rather than a new one alongside it, is what makes both of these free.

### Options set aside

**Negative `event_number` rows in `device_event`.** The real device only ever produces positive numbers (`event_number` is `UInt32` end to end) and the column carries no `CHECK`, so a hand-written negative row cannot collide with a real one and needs no schema change; `convertEligibleEvents` never inspects the sign, so a finalized manual row would convert like a real one. Set aside for what it does not avoid: `latestRecordedEvent()` orders by `start_epoch` with no clause excluding a manual row, so one would become the "newest" row on record for as long as manual mode is active and force a full history re-stream on the next real reconnect (`WHERE event_number > 0` fixes it, but is a required change, not a nice-to-have) -- and it inherits the same face-borrowing category-resolution question the virtual device has, without gaining the virtual device's reuse of an already-built, already-proven pipeline.

**A separate `manual_time_entry` table**, merged with `time_entry` only at the read layer. Manual-vs-real would have been structural, which table a row is in, rather than a sign convention, and could never collide with any of `device_event`'s ordering machinery, since it would never touch that table at all. Set aside as the most code of the three: three read paths (`loadCategoryTotals`, `loadTimeEntries`, `DailyCategoryTotals.seedFromHistory`) would need a second source merged in, an open manual segment would have no physical device to persist it if the app crashed, and it forecloses reusing a virtual device's protocol substitutability later -- exactly what the chosen option leans on.)
