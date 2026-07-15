# TimeFlip macOS

A native macOS menu bar application for the [TimeFlip2](https://timeflip.io/) time tracking device with seamless 
Google Calendar and Google Sheets integration.

## Features

- **Menu Bar Timer**: Real-time activity tracking with icon, elapsed time, and pause/play indicators
- **BLE Device Integration**: Direct connection to TimeFlip2 via Bluetooth Low Energy
- **Google Calendar Sync**: Automatically creates calendar events for completed time tracking sessions
- **Google Sheets Export**: Appends activity logs to a designated Google Sheet workbook
- **Activity Management**: Configure custom activities with icons, colors, and time limits
- **Auto-Pause Support**: Automatic pause after configurable idle time
- **Daily Statistics**: Track daily time spent per activity
- **Device Control**: LED brightness, blink intervals, and double-tap sensitivity configuration

Menu bar item preview:

![Menu bar timer](screenshot/menu-item.png)

### Not supported

- **Pomodoro timers**: totally doable, but I don't use this workflow myself and I am not sure about UX. 
  PRs are welcome

## System Requirements

- macOS 14 (Sonoma) or later
- Apple Silicon or Intel Mac with Bluetooth 4.0+
- TimeFlip2 device
- Swift 6.0+ (for building from source)

## Installation

### Building from Source

#### Option 1: Using Swift Bundler (Recommended)

The project includes configuration for [swift-bundler](https://github.com/stackotter/swift-bundler), which creates a proper macOS application bundle.

```bash
# Install Mint package manager (if not already installed)
brew install mint

# Clone the repository
git clone https://github.com/growler/TimeFlipApp.git
cd TimeFlipApp 

# Build the application bundle (runs swift-bundler via mint, no PATH changes needed)
mint run stackotter/swift-bundler@main bundle TimeFlip

# The app will be created at .build/bundler/apps/TimeFlip/TimeFlip.app
# Open the app
open .build/bundler/apps/TimeFlip/TimeFlip.app

# or run using bundler
mint run stackotter/swift-bundler@main run TimeFlip
```

You can then drag `TimeFlip.app` to your Applications folder for easy access.

#### Option 2: Direct Swift Build

```bash
# Clone the repository
git clone https://github.com/growler/TimeFlipApp.git
cd TimeFlipApp 

# Build the application
swift build -c release

# Run the application
.build/release/TimeFlipApp
```

The app will appear in your menu bar with the TimeFlip icon.

## Google Account Setup

To enable Google Calendar and Google Sheets integration, you need to create a Google Cloud project and configure
OAuth credentials.

### Step 1: Create a Google Cloud Project

1. Go to the [Google Cloud Console](https://console.cloud.google.com/)
2. Click on the project dropdown at the top and select "New Project"
3. Enter a project name (e.g., "TimeFlip Integration")
4. Click "Create"

### Step 2: Enable Required APIs

1. In your project, go to "APIs & Services" > "Library"
2. Search for and enable the following APIs:
   - **Google Calendar API**
   - **Google Sheets API**

### Step 3: Configure OAuth Consent Screen

Google's console now organizes this under "Google Auth Platform" as separate tabs (in the left sidebar)
instead of a single wizard. Configure them in this order:

1. Go to "APIs & Services" > "OAuth consent screen" (this lands you on the "Google Auth Platform" page)
2. On first visit, click "Get Started" and select "External" as the user type (unless you have a
   Google Workspace account), then fill in:
   - **App name**: TimeFlip macOS
   - **User support email**: Your email address
3. Go to the **"Branding"** tab and confirm the app name/support email/developer contact info are set
4. Go to the **"Audience"** tab:
   - Confirm "External" is selected
   - Under "Test users", click "Add Users" and **add your own email address**
5. Go to the **"Data access"** tab:
   - Click "Add or remove scopes"
   - Add the following scopes:
     - `https://www.googleapis.com/auth/calendar.events`
     - `https://www.googleapis.com/auth/calendar.readonly`
     - `https://www.googleapis.com/auth/spreadsheets`
   - Click "Update" and then "Save"

### Step 4: Create OAuth Credentials

1. Go to the **"Clients"** tab (still under "Google Auth Platform")
2. Click "Create OAuth client"
3. Select "Desktop app" as the application type
4. Enter a name (e.g., "TimeFlip Desktop Client")
5. Click "Create"
6. You'll see a dialog with your Client ID and Client Secret
7. Click "Download JSON" to save the credentials (optional, but recommended as backup)
8. Copy both the **Client ID** and **Client Secret** - you'll need these for the app

### Step 5: Configure TimeFlip App

1. Launch the TimeFlip app from your menu bar
2. Click on the TimeFlip icon and select "Preferences..."
3. Go to the "Reports" tab
4. Paste your **Client ID** in the "Client ID" field
5. Paste your **Client Secret** in the "Client Secret" field
6. Click "Sign In with Google"
7. Your default browser will open with the Google OAuth consent screen
8. Sign in with your Google account (the one you added as a test user)
9. Review the permissions and click "Continue"
10. The browser will show "Authorization complete" and you can close the window
11. Return to the TimeFlip app - you should now see "Authenticated"

![Preferences - Reports](screenshot/preferences-report.png)

### Step 6: Configure Calendar and Sheet

1. In the Reports tab preferences:
   - **Calendar**: Click "Load calendars" to fetch your Google calendars, then select the calendar where events
     should be created from the dropdown menu. You can use "Refresh calendars" to reload the list if needed.
   - **Sheet URL**:
     - Click "Set" to enter a Google Sheets URL (if you have a sheet URL in your clipboard, it will be pre-filled)
     - Press Enter to save, or Escape to cancel
     - Once set, use "Update" to change the URL or "Open" to view the sheet in your browser
     - To remove the URL, click "Update", clear the field, and press Enter

The app will now automatically sync your time tracking data to Google Calendar and Sheets.

## TimeFlip Device Setup

### Pairing Your Device

1. Ensure your TimeFlip2 device is powered on and within Bluetooth range
2. **If your device is already connected to the official TimeFlip app, you must explicitly
   disconnect it there first** — in the official app: go to **Settings**, tap the **three dots**,
   then **"Disconnect TimeFlip"**. Turning off Bluetooth on your phone is **not** enough: the
   official app appears to set a private, account-specific device password when it connects, so
   even after the Bluetooth radio link drops, the device is left on a password other than the
   default `000000` and this app won't be able to log in. Only the explicit "Disconnect TimeFlip"
   action resets it back to default.
3. Open the TimeFlip app preferences
4. Go to the "Device" tab
5. Click **"Scan for Devices"** (this button only appears while no device is paired; check
   **"All Devices"** if you don't see your TimeFlip show up under the default TimeFlip-only filter)
6. Once your device appears in the results list below, click it to attempt pairing
   - The app always tries the factory default password (`000000`) first automatically — there's
     no password field to fill in
   - It connects and verifies it's actually a TimeFlip before proceeding — this check runs in
     full isolation, so if you happen to click a device that turns out not to be a TimeFlip,
     nothing about an already-paired device is touched. A device that fails this check is struck
     through and stays that way (even across rescans) so it can't be clicked again
   - While connecting, the row shows a "Connecting… (click to cancel)" status — click it again
     (or click a different device) to abort and disconnect
   - If pairing fails because the device is on a non-default password (e.g. previously set by
     the official app, or by this app during an earlier pairing), the row shows "Wrong PIN" — see
     Troubleshooting below for how to recover
7. Once connected, the menu bar will show the current activity, and the scan controls are
   replaced by a single **"Forget Device"** button

**Forget Device** resets the device's password back to `000000` before unpairing (confirmed via
a real login attempt on the device — the app's own stored password isn't cleared unless that
reset is actually confirmed), so the device isn't left behind on a password nobody knows.

![Preferences - Device](screenshot/preferences-device.png)

### Configuring Activities

1. In Preferences > "Facets" tab
2. Each TimeFlip facet (1-12) can be assigned:
   - **Activity Name**: Custom label for the activity
   - **Icon**: Native TimeFlip icon (matching the stickers included with your device)
   - **Color**: RGB LED color shown on the device
   - **Time Limit**: Optional daily limit (turns the menu bar item red when exceeded, to make 
     you aware if you've been slacking off enough for today)

![Preferences - Facets](screenshot/preferences-facets.png)

### Device Settings

Battery level, system status, last event, and these device behavior settings live inside the
collapsed **"Advanced"** disclosure at the bottom of the Device tab:
- **Auto-Pause**: Automatically pause after X minutes of inactivity
- **LED Brightness**: Adjust LED intensity (1-100%)
- **Blink Interval**: How often the LED blinks (5-60 seconds)
- **Double-Tap Sensitivity**: Configure tap detection parameters

## Usage

### Basic Time Tracking

1. Flip your TimeFlip device to any facet to start tracking that activity
2. The menu bar shows the current activity name, icon, and elapsed time
3. Flip to another facet to switch activities
4. All completed sessions are automatically logged

### Manual Pause/Resume

- Click the menu bar icon and select "Pause" to pause tracking
- Select "Resume" to continue tracking
- Or use the keyboard shortcut: `⌘P`

### Viewing Statistics

- The app tracks daily totals for each activity
- View current day statistics in the preferences window
- Daily windows reset at midnight

### Mock Mode for Testing

For development and testing without a physical device:

```swift
// In ApplicationDelegate.swift
private let enableMockEvents = true
```

The app includes a mock device that simulates TimeFlip behavior and accepts commands via HTTP:

```bash
# Send a mock facet change event
./scripts/send_mock_event.sh
```

## Architecture

### Core Components

- **ApplicationDelegate**: App lifecycle and device management
- **MenuBarController**: Menu bar UI and timer display
- **TimeFlipBLEDevice**: Bluetooth Low Energy device driver
- **HistoryIngestor**: Event processing and logbook management
- **GoogleIntegrationCoordinator**: Syncs data to Google Calendar and Sheets
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
├─> Google Sheets Rows
└─> Menu Bar UI + Daily Stats
```

### Event Pipeline

1. Device sends notifications on facet changes or pause events
2. Driver fetches complete history from device
3. History ingested into local SQLite logbook (all but last frame)
4. Last frame (live interval) drives UI only, never persisted
5. Integrations read from logbook using cursor-based sync
6. Each integration maintains its own sync cursor

### Building and Testing

```bash
# Build and run the app bundle (recommended for testing full app behavior)
mint run stackotter/swift-bundler@main run TimeFlip

# The app bundle is left at .build/bundler/apps/TimeFlip/TimeFlip.app
open .build/bundler/apps/TimeFlip/TimeFlip.app

# Or build in debug mode directly
swift build

# Run tests
swift test

# Run with verbose logging (direct execution)
swift run

# Format code (requires SwiftLint)
swiftlint --fix
```

### Code Style

- Swift-only codebase with 2-space indentation
- Follow SwiftLint rules
- Small, testable functions with dependency injection
- Avoid over-engineering - keep solutions simple and focused

### Contributing

1. Fork the repository
2. Create a feature branch (`git checkout -b feature/amazing-feature`)
3. Commit your changes using [Conventional Commits](https://www.conventionalcommits.org/)
   - `feat: add calendar event deduplication`
   - `fix: handle device disconnect gracefully`
   - `docs: update Google OAuth setup instructions`
4. Push to your branch
5. Open a Pull Request with:
   - Purpose and motivation
   - Screenshots for UI changes
   - Documentation updates

### Security

- Never commit Google credentials, API tokens, or device passwords
- Credentials are stored in macOS Keychain

## Troubleshooting

### Device Won't Connect

- Ensure Bluetooth is enabled
- If the device doesn't show up in the scan results, try checking **"All Devices"** — the
  TimeFlip-only filter matches on advertised name/service, which isn't always reliable
- If your device is already connected to the official TimeFlip phone app, disconnect it there
  first (Settings > three dots > "Disconnect TimeFlip") — just turning off the phone's Bluetooth
  isn't enough, since the official app appears to set a private password on connect
- A device shown with strikethrough text failed the TimeFlip verification check and can't be
  clicked again this session — that's expected for genuinely different Bluetooth devices, not a
  bug
- If pairing fails with "Wrong PIN," the device isn't on the default `000000` password (likely
  because the official phone app, or a previous pairing from this app, set a custom one). There's
  no manual password field — recover via either the official app's "Disconnect TimeFlip" (if the
  device is still bound to a phone account) or a hard reset (remove and reinsert the coin-cell
  battery), both of which restore the factory default password
- Try resetting the device by removing and reinserting the battery
- Check Bluetooth permissions in System Preferences > Privacy & Security
- Check the terminal you launched the app from — connection attempts, timeouts, and the device's
  raw password-check responses are printed there for diagnostics

### Google OAuth Fails

- Verify your email is added as a test user in Google Cloud Console
- Check that all required APIs are enabled (Calendar API, Sheets API)
- Ensure the Client ID and Client Secret are correct
- Try signing out and signing in again

### Events Not Syncing to Google

- Verify you're authenticated
- Check that Calendar Name and Sheet URL are configured
- Ensure the sheet is accessible to your Google account
- Check Console.app logs for error messages (filter by "timeflip")

### Menu Bar Not Updating

- Check that the device is connected (preferences should show "Paired")
- Try manually pausing and resuming
- Restart the application

## License

This project is released into the public domain under [The Unlicense](https://unlicense.org/).

### Important Note About Icons

The TimeFlip icon set included in this project is used with permission from TimeFlip exclusively for this 
application. If you wish to fork this project, you must obtain your own permission from TimeFlip 
to use their icon assets, or replace them with your own icons.

## Acknowledgments

- Special thanks to [TimeFlip](https://timeflip.io/) for the hardware device and for graciously 
  permitting the use of their icon set in this application
- [AppAuth-iOS](https://github.com/openid/AppAuth-iOS) for OAuth implementation
- [Timeflippers](https://github.com/bzobl/timeflippers) for the Rust TimeFlip client which 
  I've been looking a lot at to get the idea of what the hell is going on in a familiar language
- Built with Swift and macOS native frameworks

## Support

For bugs and feature requests, please [open an issue](https://github.com/yourusername/timeflip/issues).

For device-related questions, visit [TimeFlip Support](https://timeflip.io/support).
