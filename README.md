# Facet

A native macOS menu bar application for the [TimeFlip2](https://timeflip.io/) time tracking device.

**Using Facet is documented at [facet.com.au](https://facet.com.au)**: installing it, pairing a cube,
setting categories up, connecting a Google account and what everything on screen means. Everything in
this repository is about *building* the app instead, and is written for whoever is working on it.

## Provenance

This is AI-generated code all the way down, and it's worth being honest about that. The original author, [growler](https://github.com/growler), vibecoded the base project - including the core Bluetooth Low Energy layer that talks to the TimeFlip2 - mostly with OpenAI Codex. They've said themselves they'd never written for macOS before. Everything I've built on top of that fork is the same story. I don't know Swift either, and the actual code was written by Claude Sonnet 5 via the VS Code plugin. The design decisions are mine (Harry Phillips), for better or worse.

## What it does

Times what a TimeFlip2 cube is doing from the macOS menu bar, files it under a category, keeps the
record in a local SQLite database and syncs it to a Google calendar of its own. With no cube paired it
times from the app instead, into the same tables. [facet.com.au](https://facet.com.au) covers all of it
from the using end.

### Not built yet

- **Firmware-update reminder**: the app reads the cube's firmware version on every connect and shows it on the Device tab, but does not yet remind anyone to go and update it. It could not do the update either way -- only the vendor's own app can flash firmware -- so this is a nudge to go there, not a feature that is half finished.
- **Projects and costs**: the `project` table and the `cost` columns exist and nothing reads or writes them.
- **Editing a recorded entry**: the Report tab lists what was recorded and cannot yet correct it, so a stretch recorded against the wrong category stays that way.

## Working on it

- **[Installation](docs/installation.md)** - system requirements, building from source, and what to run
- **[Contributing](CONTRIBUTING.md)** - code style, security guidelines, and how to submit a PR
- **[Google OAuth setup](docs/google-oauth-setup.md)** - the Google project a build signs in against
- **[Workflow](docs/workflow.md)** - the usage the schema is shaped around, and why
- **[Operation Spec](docs/operation-spec.md)** - how a device event becomes a calendar entry
- **[Database Design](docs/database-design.md)** - the local SQLite schema
- **[Features Under Development](docs/TODO-features-under-development.md)** - the longer-form notes behind individual features
- **[State Reference](docs/state-reference.md)** - the one name every state in the app goes by
- **[Scripted checks](Tests/Scripted/README.md)** - the suite that drives the real app against a real device

## Architecture

The app has no central state object, deliberately. **The database is the source of truth and is read
at the point of use**, so what would elsewhere be an `AppState` is a set of small readers over
`appdata.sqlite`, each asked its question at the moment the answer is wanted. Every module below
follows from that.

- **main.swift**: startup, in order -- prove this is the only instance, bring the database up, then
  claim the menu bar. From there Quit is the only way out.
- **MenuBarController**, **StatusItemTitle**, **StatusItemClickRouter**: the status item, what it says,
  what colour it says it in, and which half of it was clicked. The click rules live outside AppKit so
  they can be tested.
- **BluetoothRadio**, **DeviceLogin**, **DeviceCommandRules**: the Bluetooth driver -- one owner of the
  central manager, the login and PIN handshake, and the vendor's command bytes. Every command with a
  read-back defined is read back before it is believed.
- **HistoryIngestor**: brings the cube's own record of what it has been doing into `device_event`.
- **DeviceEventRecorder**: the one writer of `device_event`, and the only thing that decides whether a
  segment opens a row, grows the open one, or closes it out.
- **TimeEntryRecorder** / **TimeEntryRules**: the one writer of `time_entry`. A `device_event` is what
  the device says happened; a `time_entry` is what the app counts, and the two are different questions.
- **DayTotal** / **DayWindow** / **TimeEntryStore**: how much time a category has today, derived from
  `time_entry` plus the segment still running, over the window `daily_reset_time` defines.
- **DailyLimitEnforcement** / **CubeLock** / **ForcedPause**: the reasons the app stops the cube, and
  the one place that knows the order each of them goes out in.
- **CalendarSync**, **GoogleOAuthClient**, **GoogleCalendarClient**: signing in, and sweeping every
  unsynced `time_entry` into the calendar Facet makes for itself.
- **SettingsWindowController** and its five panes (Faces, Categories, Report, App, Device).
- **SettingStore**, **CategoryStore**, **FaceStore**, **TimezoneStore**, **IconStore**,
  **ColourStore**: a reader per table, over one connection held open for the life of the app. Holding
  a connection open is a different thing from holding a value.
- **DebugLog**: every action the app takes, as a `debug_log` row as well as a console line. It is what
  makes the scripted checks possible -- press by name, then poll for the row.

### Data Flow

```
TimeFlip Device (BLE)
    ↓
Device History Events
    ↓
device_event (SQLite) ──> time_entry (SQLite)
    ↓                         ↓
Menu Bar UI + Daily Stats   Google Calendar Events
```

### Event Pipeline

1. Device sends notifications on face changes or pause events
2. The driver first makes a cheap single-frame read of the device's current event. If that is the segment already on record, its duration alone is refreshed and nothing is streamed at all, which is what most refreshes do
3. Otherwise it streams history **from** the newest segment already recorded, so only what is new comes across. It streams from the very beginning in two cases: nothing is on record yet, or the recorded position cannot be reconciled with the device's counter (a factory reset restarts the numbering, so a post-reset event 10 is not the event 10 on file)
4. Every frame is written to `device_event`; all but the last as closed (`finalised = 1`), the last as the open segment whose duration grows until a later event closes it out
5. Closing a segment out converts it to a `time_entry` row against the category its face is mapped to, unless it was shorter than `blip_time`
6. The menu bar's daily totals are seeded from `time_entry`, not `device_event`, so reassigning a face later cannot rewrite what was already recorded against the old category. The still-open segment has no row yet, so its elapsed time is added on top rather than counted twice. The Report tab reads the same table over a chosen span

There are no sync cursors. The device resume position is a query against `device_event`.

## License

This project is released into the public domain under [The Unlicense](https://unlicense.org/).

### Important Note About Icons

The activity icons are TimeFlip's copyrighted icon set. I now have permission from TimeFlip (the copyright holder) to use them in this application, so the real icons - the ones that match the stickers on your device - are included here rather than the generic placeholder clock.

That permission was granted to me, for this project specifically, and **does not transfer with the code**. This project's licence (The Unlicense, above) covers my code - it does **not** cover TimeFlip's icons. If you fork or copy this repository and want to distribute it, or otherwise make it available to others, with these icons included, you must obtain your own permission from TimeFlip first. Without that permission, remove or replace the icons before sharing it on.

## Acknowledgments

- Original creator [growler](https://github.com/growler) - this project is forked from their [TimeFlipApp](https://github.com/growler/TimeFlipApp) repository
- Special thanks to [TimeFlip](https://timeflip.io/) for the hardware device and for graciously permitting the use of their icon set in this application
- [Timeflippers](https://github.com/bzobl/timeflippers) for the Rust TimeFlip client, which growler read while building the original app to work out what the device was actually doing, in a familiar language
- Built with Swift and macOS native frameworks

## Support

For bugs and feature requests, please [open an issue](https://github.com/tuxcomputers/TimeFlipApp/issues).
Anything about using the app, or about the cube itself, is answered at
[facet.com.au](https://facet.com.au).
