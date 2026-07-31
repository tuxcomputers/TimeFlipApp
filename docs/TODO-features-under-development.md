# Feature under development

- [x] Categories
- [x] Faces
- [ ] Time logs
- [ ] Calendar sync
- [ ] Sync to TimeFlip cloud
- [ ] Projects
- [ ] Device rename

## Categories

- Unlimited categories, created by the user.
- Any category can be assigned to any face; the same category can be assigned to multiple faces
  at the same time.
- Assigning a category the user types that doesn't exist yet creates it by default — this is the
  default action; the user also has the option to instead **rename** an existing category. Since
  historical data (e.g. `time_entry`) links to `category` by `category_id`, a rename automatically
  carries forward everywhere that history is displayed/reported — no backfill needed.
- Assignment is done by picking from a list (dropdown) of existing categories.
- New `active` column on the `category` table. An inactive (deactivated) category:
  - No longer appears in the assignment dropdown.
  - Can still be reported against, same as an active one.
  - Rationale: categories like a JIRA ticket accumulate time against them but eventually stop
    being used — deactivating hides them from future assignment without losing their history.

(Note: `face.category_id` is already a plain FK, many faces -> one category, so multiple faces
already share a category with no schema change. The new work is the `active` column plus the
create-if-missing and active-filtered-dropdown behavior.)

## Faces

- Any **active** category can be assigned to a face.
- The same category can be assigned to multiple faces at once.
- Two ways to assign:
  1. The list on the right-hand side (the existing per-face settings list).
  2. Click the **current face** (the device's currently active face) to open a dropdown of
     active categories; typing into the field filters the dropdown by the typed text.

- Category assignment **replaces** today's free-text per-face editing: a face's identity becomes
  its assigned `category_id`, and the category's own name/icon/colour (already columns on
  `category`) are what display for that face. The current free-text name field
  (`TopFaceEditor`'s `nameBinding` in `SettingsViews.swift`) goes away.

(Note: today, `TopFaceEditor` in `SettingsViews.swift` edits a face's name/icon/colour directly
per row, independent of the `category` table — there's no category-picker dropdown yet, filtered
or otherwise, and no "click the current face to assign" gesture. This is a real re-model of how a
face's display comes to be, not just an added picker, on top of the `active`-aware category list
from the Categories section above.)

## Time logs

- When a `device_event` row becomes finalised (closed out by a later event), a new `time_entry`
  row is created for it — one finalised `device_event` -> one `time_entry`.
- The new row's `category_id` is the category the face was linked to **at that time** — captured
  at creation, not looked up later. If the face's category assignment changes afterward, past
  `time_entry` rows keep pointing at the category they were actually logged against.
- Every other `time_entry` column is calculated at creation time: `started_at`/`ended_at`
  (from the `device_event`'s start and the point it closed), `duration_seconds`, `total_cost`
  (from the category's `cost`), etc. -- nothing is backfilled or recalculated after the fact.

(Note: `time_entry` (`009_time_entry.sql`) already has exactly this shape -- `category_id`,
`device_event_id`, `started_at`/`ended_at` + timezones, `duration_seconds`, `total_cost` -- but
nothing currently writes to it; there's no `INSERT INTO time_entry` anywhere in `Sources/`. This
is the feature that wires the table up: the finalised-`device_event` trigger point, the
capture-category-at-the-time behavior, and the start/end/duration/cost calculation are all new.)

## Calendar sync

- The user creates a new calendar or selects an existing one on the **App** tab.
- When a `time_entry` row is created, a sync process runs against it:
  1. Create the calendar event, with the `time_entry` id in the event's note/description.
  2. Read back the event(s).
  3. Check the read-back event's properties against the `time_entry` record to confirm the
     created event is correct.
  4. Once confirmed, mark the `time_entry` row's sync to calendar as ticked
     (`synced_to_google_calendar = 1`).

(Note: the App-tab calendar create/select UI, `GoogleCalendarEvent` model, and
`GoogleCalendarClient.insertEvent` already exist (`ReportSettingsView.swift`,
`GoogleCalendarClient.swift`) -- and `time_entry.synced_to_google_calendar` is already reserved for
this in the schema, per `docs/operation-spec.md` § 5. What's still missing: the actual background
process that reads unsynced `time_entry` rows and drives all four steps above, the calendar
event's description carrying the `time_entry` id (`GoogleCalendarEvent.description` exists but
nothing currently populates it that way), a read-back call (`GoogleCalendarClient` has no
list/get-single-event method yet, only `insertEvent`), and the property-comparison check. This
feature depends on Time logs above actually writing `time_entry` rows before it has anything to
sync.)

## Sync to TimeFlip cloud

- Design intent to be captured.

(Note: nothing in `Sources/` talks to a TimeFlip cloud API today -- no HTTP client, endpoint,
account or token for it exists; the only cloud integration currently built is Google Calendar.
The vendor's API is documented in `docs/TimeFlip API Documentation 05.2025.pdf`, which is where
the shape of this work will come from.)

## Projects

- The user creates projects.
- Multiple categories can be associated with a single project, each carrying its own cost.
- Reporting can be grouped by project.

(Note: `project` (`006_project.sql`) is currently id/name only -- "for now", per its own comment --
and `category.project_id` already links many categories to one project, so that part of the
association is already schema-supported; each category's own `cost` is what rolls up under the
project. What's missing: any project create/manage UI at all (no `Project`-named view exists
anywhere in `Sources/`), and any reporting query that groups by `project_id` -- today's reports
(`ReportSettingsView.swift`) don't reference `project` at all.)

## Device rename

- The user can give the physical TimeFlip its own name.
- The chosen name is stored in a `setting` row, and checked and restored on app startup, so the
  cube carries the user's name rather than the vendor default.
- The Scan for Devices list must match **both** the vendor default name and the stored custom
  name, so a renamed cube is still findable.

(Note: the driver can already write the name -- `TimeFlipBLEDevice.setDeviceName` sends `0x15`
-- but **nothing in the app calls it**, and there is no `setting` row for it yet. Three things
that shape the work, all confirmed against the vendor spec and the hardware:

**The name has a real read-back, unlike LED brightness and blink interval.** The spec lists
Device Name / `0x2A00` as a readable Generic Access characteristic. So "checked and restored" can
genuinely compare before writing, instead of the write-blind approach `0x09`/`0x0A` are stuck
with. But the driver has no reference to `0x2A00` anywhere, so that read is a prerequisite; until
it exists the restore can only write unconditionally on every startup.

**Do not reuse `paired_device.name`.** That row is the *advertised* name the app remembers so it
can show something while disconnected, and it is not the same string: it currently reads
`TimeFlip` while the cube advertises `TimeFlip v2.0`. Driving a rename from it would make the app
quietly rename the cube to its own display label. (Caught during a live probe on 2026-07-31,
before it ran.)

**18 ASCII characters, and the two limits differ.** The spec caps the `0x15` write at 18 symbols,
ASCII only, while `0x2A00` reads up to 20. `setDeviceName` enforces the write limit by returning
false, so an over-long or non-ASCII stored value would fail silently on every startup with only a
debug line to show for it. Validate where the setting is written, not just at the BLE call.

**A renamed cube disappears from the filtered scan, and Forget Device is when that bites.** The
discovery filter is `serviceMatches || nameMatches`, where `nameMatches` is
`peripheral.name.lowercased().contains("timeflip")`
(`TimeFlipBLEDevice.centralManager(_:didDiscover:...)`). Its own comment records that the service
UUID is **not** reliably advertised by this hardware, so in practice the name match is what finds
the cube. Rename it to something like "Solid cube" and the filtered scan stops listing it. That
is harmless while the device stays paired, because reconnects go straight to
`paired_device.uuid` rather than rescanning, but the moment the user forgets the device the only
way back is a scan, and the name that would match is no longer the one it is advertising.

The **All Devices** tick box (`scanAllDevices`, `TimeFlipSettingsView`) turns the filter off and
does list it, so this is a recovery path rather than a lockout. But it relies on the user knowing
to tick it at precisely the moment they have lost the device, which is not a reasonable thing to
require. So the filter needs to match the stored custom name as well as "timeflip" -- which in
turn means the custom-name `setting` row **must survive Forget Device**. Clearing it on forget
would destroy the one piece of information needed to find the cube again, leaving the tick box as
the only way back.

One useful interaction: `0xFE` (reset task info) deliberately leaves the name untouched, so only a
full `0xFF` factory reset clears it. A startup restore is therefore exactly what repairs the name
after the device-test runner's end-of-run factory reset, which is why that leftover needs no
separate handling once this exists. Note the same fact cuts the other way here: forgetting a
device does not un-rename it, so the cube keeps the custom name with no app left holding a record
of it unless that row is deliberately kept.)
