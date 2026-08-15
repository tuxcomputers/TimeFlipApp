# Facet

A native macOS menu bar application for the [TimeFlip2](https://timeflip.io/) time tracking device.

## Provenance

This is AI-generated code all the way down, and it's worth being honest about that. The original author, [growler](https://github.com/growler), vibecoded the base project - including the core Bluetooth Low Energy layer that talks to the TimeFlip2 - mostly with OpenAI Codex. They've said themselves they'd never written for macOS before. Everything I've built on top of that fork is the same story. I don't know Swift either, and the actual code was written by Claude Sonnet 5 via the VS Code plugin. The design decisions are mine (Harry Phillips), for better or worse.

## Features

- **Menu Bar Timer**: Real-time activity tracking with icon, elapsed time, and pause/play indicators
- **BLE Device Integration**: Direct connection to TimeFlip2 via Bluetooth Low Energy, with automatic reconnection (including on system wake from sleep) if the connection drops
- **Status Indicators**: Menu bar text color shows connection state (green/yellow) and a blinking low-battery warning at a glance
- **Device Lock Control**: Double-click to lock/unlock the device directly from the menu bar
- **Categories**: Unlimited categories with their own icon, color and daily time limit. Typing a name that doesn't exist creates it. Retiring one takes it off the faces and out of the assignment list while keeping every hour ever recorded against it
- **Faces**: Assign any category to any face, and the same category to several faces at once. A face can be locked so it keeps what it has, and a locked face's category cannot be retired out from under it
- **Manual Mode**: When the cube can't be reached at startup, time from the app instead: pick a category on the Faces tab and the clock runs on it. It lasts the launch, so quitting and starting again is the way back to the device
- **Device Rename**: Give the cube its own name. The scan matches both the vendor default and the stored name, so a renamed cube is still findable
- **Report**: Per-category totals over a chosen span of days. Spans crossing either end are clipped to the range, so two adjacent reports add up to the report over both
- **Auto-Pause Support**: Automatic pause after a configurable idle time, and optionally when the device is locked
- **Daily Statistics**: Time per category for the app's own day, which starts at a configurable reset time rather than at midnight
- **Device Control**: LED brightness, blink intervals, and double-tap sensitivity configuration

### Not supported

- **Google Calendar sync**: not implemented. Signing in to Google, and choosing or creating the calendar to write to, both work, and `time_entry.synced_to_google_calendar` is reserved in the schema, but nothing writes events to a calendar yet. See [the TODO](docs/TODO-features-under-development.md)
- **Pomodoro timers**: totally doable, but I don't use this workflow myself and I am not sure about UX. PRs are welcome

## Getting Started

- **[Installation](docs/installation.md)** - system requirements and building the app from source
- **[Configuration](docs/configuration.md)** - Google account setup, pairing your TimeFlip device, configuring activities, everyday usage, and troubleshooting
- **[Contributing](CONTRIBUTING.md)** - code style, security guidelines, and how to submit a PR
- **[Workflow](docs/workflow.md)** - how the device owner organizes activities and faces
- **[Operation Spec](docs/operation-spec.md)** - how a device event becomes a calendar entry
- **[Database Design](docs/database-design.md)** - the local SQLite schema
- **[Features Under Development](docs/TODO-features-under-development.md)** - what is built, what is not, and why each decision was made
- **[Developer Mode Removal TODO](docs/TODO-devmode.md)** - everything to remove/decide on before shipping without dev-only config/logging

## Architecture

### Core Components

- **ApplicationDelegate**: App lifecycle and device management
- **MenuBarController**: Menu bar UI and timer display
- **TimeFlipBLEDevice**: Bluetooth Low Energy device driver
- **HistoryIngestor**: Turns the device's history stream into `device_event` rows
- **AppDataStore**: The SQLite store, and where `time_entry` rows are made
- **DailyCategoryTotals**: The day's per-category totals, seeded from `time_entry` and advanced live
- **GoogleIntegrationCoordinator**: Google account and calendar lookup (no event writing yet, see Not supported)
- **AppState**: Application state and user preferences

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
- [AppAuth-iOS](https://github.com/openid/AppAuth-iOS) for OAuth implementation
- [Timeflippers](https://github.com/bzobl/timeflippers) for the Rust TimeFlip client which I've been looking a lot at to get the idea of what the hell is going on in a familiar language
- Built with Swift and macOS native frameworks

## Support

For bugs and feature requests, please [open an issue](https://github.com/tuxcomputers/TimeFlipApp/issues).

For device-related questions, contact [TimeFlip Support](mailto:support@timeflip.io).
