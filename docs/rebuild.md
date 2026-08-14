# The rebuild: what is built, what is left

The app is being rebuilt from the ground up on `feature/codeOverhaul`, one feature at a time, with the previous implementation kept in [Archive/](../Archive/) as prior art. This is the running list: nothing here is complete, so every section carries both halves, what is done and what is still owed.

Two rules shape everything below, and are worth knowing before reading it:

- **The database is the source of truth, read at the point of use** ([CLAUDE.md](../CLAUDE.md)). Nothing holds a copy of anything the database can be asked for.
- **The archive is read before each feature is built**, and each one declares whether it ignored, massaged or copied what it found. Most say massage.

`swift test` is the only suite that runs today (518 tests) and it never touches a radio, so anything involving the cube is unverified by it by definition. Features driven against a running copy of the app say so.

## The order of work

**Manual mode across every tab first, then the device.** Nothing here talks to a cube, and the app times by hand until something does, so a tab is worth building as far as manual mode takes it and no further. Every item below that needs a device to mean anything is deliberately parked, including the rest of the Faces tab: the cube graphic, the twelve device faces and locking one all wait for the device work rather than being half-built against a device that is not there.

## The list

- [ ] **[Faces tab](#faces-tab)**: the manual-mode half is built, and the cube half waits for the device work.
- [ ] **[Menu bar](#menu-bar)**: the item says what is being timed and pauses; every colour that reports a device is still missing.
- [ ] **[Device tab](#device-tab)**: nothing so far.
- [ ] **[Categories tab](#categories-tab)**: both lists are there, and a category can be created, renamed, given an icon, a colour or a limit, retired or brought back. Its cost and its project still cannot be changed.
- [ ] **[Report tab](#report-tab)**: nothing so far.
- [ ] **[App tab](#app-tab)**: the App settings section is built and all six rows write to the database.
- [ ] **[Backend](#backend)**: the recording chain is built end to end for manual mode; there is no Bluetooth at  all.

The Settings window draws its tabs Faces, Categories, Report, App, Device, so this list is the window's own order with the menu bar slotted in second. Faces is leftmost because every open of that window lands on it whatever it was last left on, and a tab that is always opened should not be one along from the first. Device is last, being where somebody goes to set a cube up or to work out what is wrong with it.

## Faces tab

### Done, in the order it was built

- [x] **The two-column layout** ([FacesPane.swift](../Sources/TimeFlipApp/FacesPane.swift)): a wide left column for what is being timed, a narrow right column for the categories to pick from.
- [x] **The category list** ([CategoryListView.swift](../Sources/TimeFlipApp/CategoryListView.swift)): one row per active category, a colour swatch holding the icon, the name beside it, on a rounded panel, to the previous app's measurements. Every row carries an `AXIdentifier` naming its category.
- [x] **The Create button**, under the list.
- [x] **Creating a category** ([CategoryCreateControl.swift](../Sources/TimeFlipApp/CategoryCreateControl.swift),  [CategoryCreateRules.swift](../Sources/TimeFlipApp/CategoryCreateRules.swift)): the button becomes a name field, and the name is decided against the whole `category` table rather than the list on screen (insert, reactivate a retired namesake, or say it already exists). A new category gets no icon and no colour, because choosing either would invent a choice nobody made.
- [x] **Timing a category**: clicking a row ends the running segment, gives the next of the app's own faces the new category, and opens a segment on it, all from one moment read for the whole gesture.
- [x] **The Timing column** ([TimingView.swift](../Sources/TimeFlipApp/TimingView.swift)): the play/pause glyph in the category's colour, the figure under it, the name under that, sized off the square the device graphic will eventually occupy. The glyph says what is happening, not what clicking does.
- [x] **Pause and resume** from the glyph: pausing ends the segment, resuming begins another, so a paused gap is not counted as time spent.
- [x] **Re-clicking the category already being timed does nothing**, rather than restarting its clock.
- [x] **The figure is the category's total for the day**, not this session's stopwatch, so a category picked up after lunch still shows the morning.
- [x] **A relaunch comes back on the last category, paused, showing the day's total.** Not restored from anywhere: whether the clock is running is read from whether `device_event` holds an open segment, so a launch inherits the answer by asking. That deleted the last in-memory copy of what is being timed.

### Still to do

Nothing until the device work, which the three items below all need. See [The order of work](#the-order-of-work).

- [ ] **The cube arrangement**: the device graphic and its lock in the left column under a "Top face" heading, which is what this pane looks like when there is a cube to follow.
- [ ] **Assigning categories to the twelve device faces.** The `face` table seeds them and nothing in the app can change what they hold.
- [ ] **Locking and unlocking a face** (`face.locked`): writes honour the column already, an assign to a locked face being refused, and there is no way to set it either way. Unlocking is also what the disabled Active box on the Categories tab points at, a category on a locked face being one that cannot be retired.

Creating a category stays here as well as arriving on the Categories tab: this is where the list is, so it is where somebody realises a category is missing. Retiring one is not here on purpose, this tab picking a category to time rather than looking after it. See [Categories tab](#categories-tab).

## Menu bar

### Done, in the order it was built

- [x] **The status item and Quit** ([MenuBarController.swift](../Sources/TimeFlipApp/MenuBarController.swift)). From here on Quit is the only way out of the app.
- [x] **The left/right split** ([StatusItemClickRouter.swift](../Sources/TimeFlipApp/StatusItemClickRouter.swift)), decided outside the AppKit it is decided inside, because the previous app's rules were nested `guard`s in a click handler no test could reach.
- [x] **The database badge** at the far left: `TEST`, `PROD` or `DB?`, in a dev build only, first because it  qualifies everything to its right.
- [x] **Every click recorded** in `debug_log`, including the clicks that deliberately do nothing.
- [x] **Settings**, opening the window.
- [x] **Pause and Resume in the dropdown**, named and enabled from the state at the moment the menu opens.
- [x] **The menu stopped depending on a delegate**, which AppKit holds weakly: the item refreshes its own menu as it presents it.
- [x] **The category and its time**: badge, icon, name, play/pause glyph, and the category's time today, with the app's name alone in place of all of it while nothing is being timed. `display_seconds` decides whether the figure carries seconds, read per draw.
- [x] **The live green** ([StatusItemTitle.swift](../Sources/TimeFlipApp/StatusItemTitle.swift)): the whole line, images included, while a session is on show.
- [x] **The right side pauses and resumes.** The left half stays the menu in every state, being the only route to Quit, and both halves ask the same question the dropdown item asks about whether there is a clock to stop.

Three gestures now pause: the glyph on the Faces tab, the dropdown item, and the right side of the status item. All three end in one implementation, because the previous app had them as separate expressions and they came to disagree.

### Still to do

- [ ] **Yellow for a reading gone stale**, once there is a connection to lose.
- [ ] **Red for a category over its `daily_limit`**, and the pause that goes with it. The limit itself is now settable on the Categories tab, so this is the half that reads it.
- [ ] **The low-battery red/white blink**, gated on `low_battery_level`.
- [ ] **The lock badge**, to the left of the play/pause glyph rather than in place of it.
- [ ] **The double-click gesture that locks the cube**, which is also what makes the right side's pause wait out the  double-click interval instead of firing at once.
- [ ] **Tooltips that tell the two dead states apart**: no device paired, versus a paired one out of reach.
- [ ] **A "Connecting…" title** while a connection is being made.

## Device tab

Nothing so far. Nothing talks to the cube yet, and manual mode stands in for all of it.

### Still to do

- [ ] **Scan, pair, and forget a device** (`paired`, `device_uuid`).
- [ ] **Connection status, and reconnecting on launch** (`connection`). Note the measured trap: reconnecting is a scan, and nothing in `swift test` scans.
- [ ] **Battery level**, from the Battery Level characteristic.
- [ ] **Lock and unlock**, and `pause_on_lock` (locking pauses first, so nothing is recorded while the cube is unattended).
- [ ] **Renaming the cube** (`device_name`, including `previous_name`, because the name macOS reports is one connection stale after a rename).
- [ ] **Auto-pause delay** (`auto_pause_minutes`, whole minutes only, which is all the device supports).
- [ ] **LED brightness and blink interval** (`led_settings`), the only two LED properties the protocol exposes.
- [ ] **Double-tap parameters** (`double_tap_settings`), seeded from a real device's registers.
- [ ] **The firmware-check reminder** (`firmware_check`), there being no way for this app to read the version.
- [ ] **Factory reset**, and what it means for the remembered name and uuid.

## Categories tab

This is where a category is looked after, as opposed to picked to time. The Active list is on it, with the archive's five columns and two of them live.

### Done, in the order it was built

- [x] **The Active list** ([CategoriesPane.swift](../Sources/TimeFlipApp/CategoriesPane.swift), [CategoryTable.swift](../Sources/TimeFlipApp/CategoryTable.swift)): a bold heading and, under it, captioned columns and one row per active category, the two of them on one tinted panel. The previous app's shape and its measurements, and a different list from the Faces tab's on purpose: that one is a pick list, this is a record of what each category is, in columns that line up so one property can be read down the tab. The tint follows the same split, the archive's pick list being plain white with hairlines and its settings panels tinted.
- [x] **The daily limit** ([CategoryEditRules.swift](../Sources/TimeFlipApp/CategoryEditRules.swift), [SteppedNumberField.swift](../Sources/TimeFlipApp/SteppedNumberField.swift)): a number field bounded 0 to 1440, a day of minutes being the most a day's budget can hold. **Stored and enforced by nothing yet**, since what reads it is the over-limit colouring and the pause sent to a spent cube, both still to come.
- [x] **The arrows accelerate while held** ([StepperHoldRules.swift](../Sources/TimeFlipApp/StepperHoldRules.swift)): ticks of 1 until the value passes the second multiple of 5 beyond where the hold began, then 5s at a slower cadence. The archive's rule copied as it stands, tests included; the arrows themselves are a hand-built chevron pair, a stock stepper repeating at one fixed increment.
- [x] **Retiring a category**, by unticking Active. It comes off every face holding it at the same time, and is barred outright while a *locked* face holds it: retiring clears faces and a locked face keeps what it has, so the app does neither and the tooltip names the face.
- [x] **Creating a category here too** ([CategoryCreateControl.swift](../Sources/TimeFlipApp/CategoryCreateControl.swift)): the same control the Faces tab has, under the list, which is where the archive put it -- in the gap between the two lists rather than inside either, so it belongs to the tab and not to one section of it. Both end in one method against the same rules and the same writer, two ways in rather than two implementations.
- [x] **The Inactive list** ([RetiredCategoryTable.swift](../Sources/TimeFlipApp/RetiredCategoryTable.swift)): the retired categories, with the box that brings one back, the name, and when it last recorded time. Its own type rather than the Active table with columns switched off, which is how the archive drew it: that list is a record of what a category *is*, this one of what it *was*, so the icon, the colour and the limit are absent rather than dead.
- [x] **The sections fold** ([CategorySection.swift](../Sources/TimeFlipApp/CategorySection.swift)): Active open because it is the one being worked in, Inactive closed because it is an archive to go looking in occasionally. The triangles waited for the second list, a lone section having nothing to fold away from.
- [x] **The heading sits on the tinted panel with its list**, which is what the archive drew: each section was a `Section` of a grouped form, and a grouped form's box holds the disclosure label as its first row. The tint moved off the two lists to do it, since a list drawing its own box inside the section's would stack two translucent fills and leave the rows darker than the heading over them. Folding now closes the panel around the heading as well: hiding the list left its full height behind, Auto Layout not caring that a view is hidden, which was a gap on a plain background and would have been an empty tinted box on this one.
- [x] **Reactivating a category**, by ticking Active on a retired row. The name is checked first, since only one active category may hold one: the unique index would refuse it anyway, but a refused write cannot say *which* category is in the way, and that is the whole of what the message needs.
- [x] **Creating against a retired namesake asks** rather than deciding: a dialogue naming the category, saying how many share the name, and offering Reactivate, Create new one, and Cancel. With more than one retired namesake the Reactivate button is absent, there being no answer to which of them was meant -- and the count is what says why.
- [x] **The icon picker** ([IconGrid.swift](../Sources/TimeFlipApp/IconGrid.swift), [IconStore.swift](../Sources/TimeFlipApp/IconStore.swift)): the row's icon opens a popover of the 42 seeded icons, six wide, which is what lays them out as an even 6 by 7 with nothing to scroll. Re-clicking the icon a category already has clears it, which is the archive's rule and the reason a grid with no None cell can still unset one.

- [x] **The colour picker** ([ColourList.swift](../Sources/TimeFlipApp/ColourList.swift), [ColourStore.swift](../Sources/TimeFlipApp/ColourStore.swift)): the row's swatch opens a popover of the 20 seeded colours, in the palette's own order rather than alphabetically, each with its name beside it. A list rather than a grid, which is the archive's shape and its reasoning: an icon is recognisable as a picture and a colour is not, so "Maroon" and "Brown" need the word to tell them apart. Re-clicking the colour a category already has clears it, as the icon grid does.

- [x] **Renaming a category** ([EditableNameCell.swift](../Sources/TimeFlipApp/EditableNameCell.swift), [CategoryRenameRules.swift](../Sources/TimeFlipApp/CategoryRenameRules.swift)): **clicking the name** turns it into a field, rather than the previous app's right-click menu with *Edit* as its only item. Return commits, a click anywhere else abandons it, and so does Escape, which the window lends the field while it is open. Every rename is confirmed, because everything references a category by id: nothing recorded is lost, and reports covering time *before* the rename show the new name too. A name a retired category holds is allowed and says how many share it; one an active category holds is a dead end. All three dialogues can be cancelled.

- [x] **A locked face freezes the whole row** ([CategoryEditRules.swift](../Sources/TimeFlipApp/CategoryEditRules.swift)): the name, the icon, the colour and the daily limit as well as the Active box, each saying on hover which face is in the way and that unlocking it is on the Faces tab. The archive barred retiring alone, on the narrower reading that retiring is what takes a category off a face; this is the wider reading, and it matches what locking a face is for, since half of what a face shows -- the artwork and the colour it lights -- lives on the category. Only the two controls that draw nothing else grey out: a greyed swatch would be a different colour, and a grey name reads as a retired category, so those decline the click instead. **One locked face is enough**, however many unlocked ones also hold the category: editing it changes what the locked face shows, and the unlocked ones are not asking for anything. Only the locked one is named in the tooltip.

### Still to do
- [ ] **A cost** (`category.cost`), which `time_entry.total_cost` is worked out from.
- [ ] **Projects** (`project`, `category.project_id`): the table exists and nothing reads it.

## Report tab

Nothing so far.

### Still to do

- [ ] **The day's entries**, from `time_entry` joined to its `device_event`.
- [ ] **Editing and deleting an entry**, which is the only way to correct a stretch recorded against the wrong category.
- [ ] **Totals**, per category and eventually per project.
- [ ] **Costs** (`time_entry.total_cost`).
- [ ] **A calendar view** of the recorded time.
- [ ] **Google Calendar sync** (`google_account`, `time_entry.synced_to_google_calendar`).

## App tab

The section is built and every row writes. Several of these settings were already honoured where they are used, so the behaviour was there ahead of the controls; what the controls add is the ability to change it.

### Done, in the order it was built

- [x] **The App settings section** ([AppSettingsPane.swift](../Sources/TimeFlipApp/AppSettingsPane.swift), [AppSettingsRules.swift](../Sources/TimeFlipApp/AppSettingsRules.swift)): the archive's six rows in its order and its wording -- show seconds, pause on lock, daily reset at, battery warning at, fetch history every, ignore flips under -- on the same tinted panel the Categories tab uses, spanning the window's width as every tab's content does ([CLAUDE.md](../CLAUDE.md)). Drawn as the archive's grouped form: the label against the left inset, the control against the right one, and a hairline between rows. The Google section that sat above it in the archive is not here: it belongs to an integration this app has not rebuilt, and an empty one would promise something.
- [x] **Every bound and default carried over with its reason** ([AppSettingsRules.swift](../Sources/TimeFlipApp/AppSettingsRules.swift)): the 20% battery cap, the 0-to-30-second blip filter, the minute-to-hour fetch interval, and an AM-only reset hour, which is a control the archive reduced to one field after finding that PM was only ever a way to pick a wrong value. Each default is the seed in `database/011_setting.sql`, since `SettingReader` answers `nil` for a missing row and refuses to guess what absence means.
- [x] **The values are read from `setting` when the tab is shown**, like every other pane's, rather than drawn from placeholders. A row showing a number that is not the stored one is exactly the two-answers problem the first design rule exists to prevent.
- [x] **The rows write, and the window is the source of truth while it is open** ([SettingStore.swift](../Sources/TimeFlipApp/SettingStore.swift), and the rule in [CLAUDE.md](../CLAUDE.md)): opening reads every tab's settings in one go, a changed field is written straight through and **checked by reading it back**, and the change is adopted only once the table has it. A refused write puts the row back and raises an alert naming the row. A value the table gained meanwhile is overwritten -- the window read it at open and has been the answer since. Closing ends it, so the next open finds whatever is there.

### Still to do

- [ ] **A battery reading**, which is what `low_battery_level` needs before it means anything. The row stores the threshold; nothing reports a level to judge against it yet.
- [ ] **The debug settings** (`debug`: whether to gather messages, whether to write them to a file, and where), which are a placeholder row and nothing else.

## Backend

### Done, in the order it was built

- [x] **The database at launch** ([DatabaseBootstrap.swift](../Sources/TimeFlipApp/DatabaseBootstrap.swift),  [DatabaseConnection.swift](../Sources/TimeFlipApp/DatabaseConnection.swift)): the DDL in [database/](../database/) creates it, one read connection is held open for the life of the app, and a reader per table sits on top ([SettingReader](../Sources/TimeFlipApp/SettingReader.swift),  [CategoryStore](../Sources/TimeFlipApp/CategoryStore.swift), [FaceStore](../Sources/TimeFlipApp/FaceStore.swift), [TimezoneStore](../Sources/TimeFlipApp/TimezoneStore.swift)). Holding a connection open is a different thing from holding a value.
- [x] **The developer flag and the debug log** ([DeveloperMode.swift](../Sources/TimeFlipApp/DeveloperMode.swift), [DebugLog.swift](../Sources/TimeFlipApp/DebugLog.swift)): one flag decides what exists, every message is timestamped and tagged with the tags padded to a common width, and rows go to `debug_log` as well as the console. This is what makes checking the app against a running copy possible: press by name, then poll for the row.
- [x] **One instance only** ([InstanceLock.swift](../Sources/TimeFlipApp/InstanceLock.swift)): a kernel lock on an  open file descriptor, claimed before a database is opened or a status item claimed. A kernel lock rather than "whoever started first wins", because an instance launched directly reports no launch date.
- [x] **Manual mode** ([ManualMode.swift](../Sources/TimeFlipApp/ManualMode.swift)), derived from whether a device is paired rather than published as a second flag beside the connection status.
- [x] **The timing session, built and then removed.** It held what was being timed and since when, in memory, on the reading that it described this launch. It was a second answer to a question `device_event` already answered, and a relaunch is where the two parted company: the table knew the category, the flag did not. An open segment is now what running means, and nothing holds it. Kept on this list because the shape it left is why the readout looks as it does.
- [x] **The `device_event` writer** ([DeviceEventRecorder.swift](../Sources/TimeFlipApp/DeviceEventRecorder.swift), [DeviceEventRules.swift](../Sources/TimeFlipApp/DeviceEventRules.swift)): the one writer of that table, and the module that decides whether a segment opens a row, grows the open one, or closes it out. Identity is `(event_number, start_epoch)`; durations are whole seconds, as the device reports them; in manual mode the  event number is the unix second.
- [x] **The history timer** ([HistoryTimer.swift](../Sources/TimeFlipApp/HistoryTimer.swift)): one-shot, re-armed after every timeout, re-reading its interval each time. With no cube to ask, the timeout is the source: the app reports its own open segment and the recorder recognises it as the same event.
- [x] **Two manual faces** ([ManualTimerRules.swift](../Sources/TimeFlipApp/ManualTimerRules.swift)): faces 13 and 14, above the twelve a cube can report, used in rotation so a finished segment and the one starting are never on the same face. That removes the category-attribution race rather than ordering around it.
- [x] **The `time_entry` writer** ([TimeEntryRecorder.swift](../Sources/TimeFlipApp/TimeEntryRecorder.swift), [TimeEntryRules.swift](../Sources/TimeFlipApp/TimeEntryRules.swift)): handed the id of a closed segment, it reads the row itself, reads `blip_time` first, and decides whether the stretch counts. `device_event` is what a source says happened; `time_entry` is what the app counts.
- [x] **The day's total** ([TimeEntryStore.swift](../Sources/TimeFlipApp/TimeEntryStore.swift), [DayWindow.swift](../Sources/TimeFlipApp/DayWindow.swift), [DayTotal.swift](../Sources/TimeFlipApp/DayTotal.swift)): per category rather than per face, over the window `daily_reset_time` defines, clipped at both ends, plus the segment still running. Derived every time rather than accumulated, which is what makes double counting impossible.
- [x] **The quit sequence** ([QuitSequence.swift](../Sources/TimeFlipApp/QuitSequence.swift)): the open segment is closed on the way out.
- [x] **Startup recovery**: a segment left open on one of the app's own faces is closed before anything else reads the table, keeping its last written duration, because "now" can be wrong by days. Rows on device faces are left alone, a cube timing whether or not the app is running.
- [x] **One reading of what is being timed** ([TimingReadout.swift](../Sources/TimeFlipApp/TimingReadout.swift)): the face, the category on it, whether an open segment says it is running, and the day's total, read together and drawn by both the Faces tab and the status item. Nothing in the app holds any of it, which is what lets a launch pick up where the last one stopped.

### Still to do

- [ ] **The BLE driver**, which is all of it: scan, connect, login, the history stream, live face and pause events, and the commands the Device tab needs. See [docs/TimeFlip2 BLE Protocol v4.3.md](TimeFlip2%20BLE%20Protocol%20v4.3.md) for the contract and [docs/timeflip2-firmware-observations.md](timeflip2-firmware-observations.md) for where the real device  disagrees with it.
- [ ] **Writing settings.** `SettingReader` reads and nothing writes, which every tab above needs before it can save anything.
- [ ] **Daily limit enforcement**: measuring a category against `category.daily_limit`, pausing the cube when it is spent, and refusing a resume. The archive's own scar to avoid: the pause is not idempotent, so each repeat mints a `device_event`.
- [ ] **`device_notification`**: the table exists and nothing writes it, so a double-tap or a low battery leaves no record.
- [ ] **Per-tick logging for the history timer**, which currently says nothing between "started" and a segment changing. Logging every timeout that wrote, plus the first skip after a run of writes, would show the cadence without a row a second.
- [ ] **The real developer-mode gate.** `DeveloperMode.isEnabled` is a hardcoded `true`, which is fine while the app is unreleased and must not ship that way.
- [ ] **The device tests.** There is no suite: the previous one is in [Archive/Tests/](../Archive/Tests/) and [Archive/testrunner/](../Archive/testrunner/), to be rebuilt per feature as each lands.
- [ ] **The schema migration path for a released app** (a `099` script and a `database_version` row). Until release, [database/CLAUDE.md](../database/CLAUDE.md) holds the rule instead: write the DDL as if the database were new, then bring prod and test up to it.

### Supporting material, built

- [x] [scripts/switch-database.sh](../scripts/switch-database.sh) points the app at `test.sqlite` or  `production.sqlite`. Keeping what is there is the default for both; `-clean` rebuilds, and is refused for prod.
- [x] [Tests/Methods.md](../Tests/Methods.md), the new suite's shared methods, numbered and written as they are learned: press anything by name, open the status item's menu, read the accessibility tree, confirm what the app did from `debug_log`, confirm an appearance by measuring it.
- [x] [scripts/ax-press.py](../scripts/ax-press.py), [scripts/ax-dump.py](../scripts/ax-dump.py) and [scripts/status-item-click.py](../scripts/status-item-click.py), which are that layer: every element carries an `AXIdentifier` and every click leaves a row, so a step is "press by name, then poll for the row".
