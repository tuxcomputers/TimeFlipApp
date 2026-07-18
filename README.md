# TimeFlip macOS

A native macOS menu bar application for the [TimeFlip2](https://timeflip.io/) time tracking device with seamless 
Google Calendar integration.

## Provenance

This is AI-generated code all the way down, and it's worth being honest about that. The original
author, [growler](https://github.com/growler), vibecoded the base project — including the core
Bluetooth Low Energy layer that talks to the TimeFlip2 — mostly with OpenAI Codex. They've said
themselves they'd never written for macOS before. Everything I've built on top of that fork is the
same story. I don't know Swift either, and the actual code was written by Claude Sonnet 5 via the
VS Code plugin. The design decisions are mine (Harry Phillips), for better or worse.

## Features

- **Menu Bar Timer**: Real-time activity tracking with icon, elapsed time, and pause/play indicators
- **BLE Device Integration**: Direct connection to TimeFlip2 via Bluetooth Low Energy, with automatic
  reconnection (including on system wake from sleep) if the connection drops
- **Status Indicators**: Menu bar text color shows connection state (green/yellow) and a blinking
  low-battery warning at a glance
- **Device Lock Control**: Double-click to lock/unlock the device directly from the menu bar
- **Google Calendar Sync**: Automatically creates calendar events for completed time tracking sessions
- **Activity Management**: Configure custom activities with icons, colors, and daily time limits
- **Auto-Pause Support**: Automatic pause after configurable idle time
- **Daily Statistics**: Track daily time spent per activity
- **Device Control**: LED brightness, blink intervals, and double-tap sensitivity configuration

Menu bar item preview:

![Menu bar timer](image/menu-item.png)

### Not supported

- **Pomodoro timers**: totally doable, but I don't use this workflow myself and I am not sure about UX. 
  PRs are welcome

## Getting Started

- **[Installation](docs/installation.md)** — system requirements and building the app from source
- **[Configuration](docs/configuration.md)** — Google account setup, pairing your TimeFlip device,
  configuring activities, everyday usage, and troubleshooting
- **[Contributing](CONTRIBUTING.md)** — code style, security guidelines, and how to submit a PR
- **[Workflow](docs/workflow.md)** — how the device owner organizes activities and faces
- **[Operation Spec](docs/operation-spec.md)** — how a device event becomes a calendar entry
- **[Database Design](docs/database-design.md)** — the local SQLite schema
- **[Developer Mode Removal TODO](docs/TODO-devmode.md)** — everything to remove/decide on before
  shipping without dev-only config/logging

## Architecture

### Core Components

- **ApplicationDelegate**: App lifecycle and device management
- **MenuBarController**: Menu bar UI and timer display
- **TimeFlipBLEDevice**: Bluetooth Low Energy device driver
- **HistoryIngestor**: Event processing and logbook management
- **GoogleIntegrationCoordinator**: Syncs data to Google Calendar
- **AppState**: Application state and user preferences

### Data Flow

```
TimeFlip Device (BLE)
    ↓
Device History Events
    ↓
Logbook Database (SQLite)
    ↓
├─> Google Calendar Events
└─> Menu Bar UI + Daily Stats
```

### Event Pipeline

1. Device sends notifications on facet changes or pause events
2. Driver fetches complete history from device
3. History ingested into local SQLite logbook (all but last frame)
4. Last frame (live interval) drives UI only, never persisted
5. Integrations read from logbook using cursor-based sync
6. Each integration maintains its own sync cursor

## License

This project is released into the public domain under [The Unlicense](https://unlicense.org/).

### Important Note About Icons

The TimeFlip icon set included in this project is used with permission from TimeFlip exclusively for this 
application. If you wish to fork this project, you must obtain your own permission from TimeFlip 
to use their icon assets, or replace them with your own icons.

## Acknowledgments

- Original creator [growler](https://github.com/growler) — this project is forked from their
  [TimeFlipApp](https://github.com/growler/TimeFlipApp) repository
- Special thanks to [TimeFlip](https://timeflip.io/) for the hardware device and for graciously 
  permitting the use of their icon set in this application
- [AppAuth-iOS](https://github.com/openid/AppAuth-iOS) for OAuth implementation
- [Timeflippers](https://github.com/bzobl/timeflippers) for the Rust TimeFlip client which 
  I've been looking a lot at to get the idea of what the hell is going on in a familiar language
- Built with Swift and macOS native frameworks

## Support

For bugs and feature requests, please [open an issue](https://github.com/tuxcomputers/TimeFlipApp/issues).

For device-related questions, contact [TimeFlip Support](mailto:support@timeflip.io).
