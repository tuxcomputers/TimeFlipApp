# Configuration

[← Back to README](../README.md) · [Installation](installation.md)

Once the app is installed and running (see [Installation](installation.md)), use this guide to connect your Google account, pair your TimeFlip device, and configure activities.

## Google Calendar

**There is nothing to set up.** The OAuth client ships inside the app, so signing in is one button:

1. Open **Settings** from the menu bar item, go to the **App** tab, and open the **Google** section at the bottom
2. Click **Sign in with Google**
3. Your browser opens Google's consent screen. Sign in and approve
4. The browser says the authorization is complete; close it and return to Facet
5. The section now shows **Status**, the account **Name** and **Email**, and the calendar

Facet asks for four permissions and no more: your name, your email address, sign-in itself, and
**permission to manage calendars this app creates** (`calendar.app.created`). It deliberately does not
ask to read your existing calendars or write to them, so it cannot see or touch anything it did not
make. That is why there is no calendar picker: Facet makes a calendar of its own, named `Facet`, and
that is the only one it can write to.

From then on, recorded time goes across on its own. Each entry is created and then **read back and
checked** before the entry is marked synced, and every sweep carries whatever failed last time, so
time recorded while offline goes over on the next one.

**Rename or delete the calendar** from the same section. Both happen at Google, not just as a label
here, and deleting is behind a confirmation since it takes the events with it.

> **Building it yourself?** Drop the Google console's downloaded JSON at
> `~/.config/facet/google-client.json`, unedited, and build with `scripts/run.sh`. It copies the pair
> into the app so a build handed to somebody else can sign in too, and `FACET_GOOGLE_CLIENT_JSON`
> overrides it for pointing at a second project. **With no such file the app still builds and runs**;
> the Google section simply says this copy has no credentials. Setting up the project itself is
> documented once, for whoever publishes the binary, in
> [google-oauth-setup.md](google-oauth-setup.md).

> **If macOS asks for Keychain access after every rebuild**, the build was ad-hoc signed. Build through
> `scripts/run.sh`, which finds a codesigning identity and uses it; see
> [google-oauth-setup.md](google-oauth-setup.md).

## TimeFlip Device Setup

### Pairing Your Device

1. Ensure your TimeFlip2 device is powered on and within Bluetooth range
2. **If your device is already connected to the official TimeFlip app, you must explicitly disconnect it there first** — in the official app: go to **Settings**, tap the **three dots**, then **"Disconnect TimeFlip"**. Turning off Bluetooth on your phone is **not** enough: the official app appears to set a private, account-specific device password when it connects, so even after the Bluetooth radio link drops, the device is left on a password other than the default `000000` and this app won't be able to log in. Only the explicit "Disconnect TimeFlip" action resets it back to default.
3. Open the Facet preferences
4. Go to the "Device" tab
5. Click **"Scan for Devices"** (this button only appears while no device is paired; check **"All Devices"** if you don't see your TimeFlip show up under the default TimeFlip-only filter)
6. Once your device appears in the results list below, click it to attempt pairing
   - The app always tries the factory default password (`000000`) first automatically — there's no password field to fill in
   - It connects and verifies it's actually a TimeFlip before proceeding — this check runs in full isolation, so if you happen to click a device that turns out not to be a TimeFlip, nothing about an already-paired device is touched. A device that fails this check is struck through and stays that way (even across rescans) so it can't be clicked again
   - While connecting, the row shows a "Connecting… (click to cancel)" status — click it again (or click a different device) to abort and disconnect
   - If pairing fails because the device is on a non-default password (e.g. previously set by the official app, or by this app during an earlier pairing), the row shows "Wrong PIN" — see Troubleshooting below for how to recover
7. Once connected, the menu bar will show the current activity, and the scan controls are replaced by a single **"Forget Device"** button

**Forget Device** is local bookkeeping: the app drops the pairing and stops trying to reconnect. It does **not** talk to the device, does not change the device's PIN, and does not change the PIN the app has stored. It works whether or not the device is connected or even in range, which is the point — forgetting is how you recover from a device the app can no longer reach.

It clears `paired`, `device_uuid` and `device_info`, and deliberately **keeps `device_name`**: forgetting does not un-rename a cube, and once a cube has been renamed off "TimeFlip" that stored name is the only thing the filtered scan can match it on.

It used to reset the device's password to `000000` first and refuse to unpair unless that reset was confirmed. That made it useless in exactly the situation it exists for: a cube whose PIN has changed underneath the app (pulling the battery reverts it to the vendor default) refuses the app's login, so the reset could never be sent, and the app reported "Could not confirm password reset — device left paired" with no way out through the UI. Changed 2026-08-11.

Since forgetting leaves the device's PIN alone, a cube that was given a PIN of its own still holds it afterwards — and re-pairing still reaches it, because the PIN the app stored is the second of the two passwords pairing presents.

**Pairing presents exactly two PINs, in this order, in every build:**

1. `000000`, the factory default — a cube that is new to the app, or has been power-cycled (pulling the battery reverts the PIN).
2. **The stored PIN** — the cube this app paired before, whose PIN it set itself.

Each is tried on a connection of its own. If neither is accepted, pairing fails and says "Wrong PIN". There is no third attempt: a cube on some other PIN is one neither the app nor its user can name, and searching for it would be a lockout dressed up as a feature.

**Whether a cube is given a PIN of its own depends on the build, and a release build gives it none.** Setting a PIN is only safe once there is somewhere durable to keep it, and a PIN the app cannot write down would lock the cube out of every app including this one — so a build that has no such store leaves the cube on whatever PIN let it in. Today only a developer build sets one: the fixed `123456`, written to `config.json`, so a dev cube's PIN is always known and typeable.

If `config.json` names no PIN at all, that constant stands in as the *stored* one. With nothing written down, a dev build can still reach a cube on either `000000` or `123456`, the two values a dev cube is ever left on. It stands in **as** the second candidate rather than joining as a third — offered as a third guess it would let a build into a cube whose PIN the app had no record of, which is a bug the previous app actually shipped.

### Renaming Your Device

**Click the name.** Settings → **Device**, and the **Name** row at the top of the TimeFlip section: clicking it turns
the name into a field. Return renames the device; Escape, or a click anywhere else, leaves it alone. It is the same
gesture that renames a category.

The row only opens while the TimeFlip is connected, and says why when it will not: the name lives on the device, so
renaming it is a command that has to reach the hardware rather than a note Facet keeps to itself.

Names are limited to **18 characters** of plain, unaccented text (letters, numbers, spaces and ordinary punctuation). That is the TimeFlip's own limit: the vendor's protocol defines the name field as "18 symbols MAX. ASCII coding", so an emoji or an accented letter cannot be sent to the device at all.

A name the device cannot store is refused when you press Return, with an alert saying what will work. Nothing is
sent to the device in that case, and the name it is carrying does not change. There is no confirmation dialogue for a
name it *can* store: renaming a device changes nothing that was recorded, so there is nothing to warn about.

#### The new name takes a while to show up everywhere else

Facet shows the new name at once and keeps showing it. **Everywhere else lags**, and there is nothing this app can do
about either half. Both are measured on real hardware (see [firmware observations](timeflip2-firmware-observations.md)):

- The name the TimeFlip broadcasts while advertising **never changes at all**. Any Bluetooth scan, in this app or any
  other, goes on listing it as `TimeFlip v2.0` forever.
- The name it reports once connected is only read at connect time and is never pushed to a Mac that is already
  connected, so macOS itself can hand out the previous name until it next connects to the device.

Facet says this in an alert as the rename lands, so a scan list still showing the old name does not read as a rename
that failed.

This is also why Facet stores **both** the current name and the one before it, and matches a scan against the vendor
default and both of them: a cube renamed a moment ago is still advertising something else, and matching only the new
name would lose it, which is exactly how the previous version of this app once made a renamed cube unreachable.

**A reconnect will not undo the rename**, even when macOS reports the old name on it. Facet keeps the name it wrote and
ignores that one reading, because the reading is a connection out of date rather than news; a name the device is given
in the vendor's app is picked up normally.

### Assigning categories to faces

**A face does not have a name of its own.** It holds a *category*, and the category's name, icon and colour are what show for that face. Two faces can hold the same category, and their time adds up as one.

1. Settings > **Faces** tab. The cube is drawn on the left, with the face it is resting on named underneath; the categories are listed on the right
2. **Turn the cube to the face you want to set**, then **click a category** in the list. That category is now on that face
3. To create one that does not exist yet, press **Create** under the list and type the name

**Locking a face.** The padlock beside the face name freezes what that face holds: clicks on the category list stop assigning to it, and the category on it cannot be retired out from under it on the Categories tab. Click the padlock again to unlock. Faces 2 and 8 are seeded locked on a new database.

**Icon, colour and daily limit belong to the category**, not to the face, and are set on the **Categories** tab — all three describe the activity being measured, so two faces holding the same category share them.

- **Icon**: click the icon on a category's row for a grid of the 42 TimeFlip icons (the ones matching the stickers). Clicking the icon it already has clears it.
- **Colour**: click the swatch for the palette. This is the colour the device lights that face up in. A category with **no** colour leaves the face's LED **dark** — clearing a colour turns the light off rather than leaving the previous one lit. Clicking the colour it already has clears it.
- **Daily Limit**: optional, in whole minutes, 0 for none. This is a **hard** limit: the figure reaching it pauses the cube, and the app then refuses to resume while that category is still the one on show. Flipping to a face whose category still has budget resumes it. It resets at `daily_reset_time` (3am by default) — see Status Indicators below.

### Device Settings

The Device tab has **two** sections, each folding away behind its own heading:

- **TimeFlip** — the cube itself: name, connection status and battery level, a collapsed **More** row
  with manufacturer/model/hardware/firmware, and under them the controls that change with the state.
  **Scan for Devices** while nothing is paired; **Forget Device** and **Reset Device** once something
  is. Reset is a full factory reset, behind a confirmation dialog since it erases everything on the
  device — including its name, which is why a confirmed reset is the one thing that makes Facet forget
  the stored name too.
- **Settings** — the cube's own settings, stored here and sent to it. They are drawn rather than hidden
  when no cube is connected, because they are readable and meaningful without one; the controls
  themselves go dead, since there is nothing to send to.
  - **Auto-pause**: pause the device after this many minutes on one face. `0` disables it, 240 is the
    maximum. Whole minutes only, which is all the device supports.
  - **LED** (collapsed): brightness (1-100%) and blink interval (5-60 seconds).
  - **Double tap** (collapsed): tap detection sensitivity — see below.

**These were three sections until 2026-08-22**, with the readings under an "Info" heading and the scan
under a "TimeFlip" of its own. One section now, because the split asked you to know that what a cube
*is* and how to *get* one are different subjects: the name of the paired device and the button that
pairs it were a panel apart.

**Every writing control here is read back before it is believed.** Auto-pause and the four double-tap
registers are sent to the cube, then read back off it, and only written down once the cube's own answer
agrees — a refusal by either the cube or the database puts the field back and says so in an alert. The
two LED values are the exception, and not an oversight: the vendor protocol defines no read-back for
either, so the write really is all there is.

#### Double-Tap Sensitivity

The device recognizes a double-tap in two stages: a quick knock (checked against **Threshold** and **Limit**), then a second one arriving within a timing window (**Latency** then **Window**). The **Disable** checkbox turns double-tap detection off on the device without losing your saved values here -- switch it back on and your settings are re-applied exactly as they were.

- **Threshold** -- how hard a tap must be.
  - Desk is wobbly and the device pauses on its own from bumps? Raise this so it takes a proper whack to register.
  - Need a hammer just to get it to notice a tap? Lower this so it's more sensitive.
- **Limit** -- how long a tap can last and still count as a tap, not a slow push.
  - Picking up or resting the device is accidentally counting as a tap? Lower this so only a sharp, quick knock registers.
  - Genuine taps getting missed? Raise this to allow a slightly longer knock through.
- **Latency** -- how long it deliberately ignores everything right after the first tap, before it starts listening for the second.
  - One single hard tap sometimes counts as a double-tap on its own (its own vibration tricking it)? Raise this so it waits longer before listening again.
  - Tapping twice quickly only registers as one tap? Lower this so it starts listening for the second tap sooner.
- **Window** -- once listening, how long the second tap has to arrive.
  - You tap slowly and the second knock keeps arriving too late to count? Raise this to give yourself more time between taps.
  - A second, unrelated bump long after the first is being counted as a double-tap? Lower this so the second tap has to land quickly.

All four are raw accelerometer register values (0-255), not a real-world unit like seconds -- there's no documented conversion, so treat them as a relative scale and adjust by feel.

### App Settings

The **App** tab, under "App settings". Every numeric row here is the same control: type a value or hold the arrows to step it, and it commits on Return or when focus leaves.

- **Show seconds** (`display_seconds`, default on): whether a time reads to the second or to the minute, wherever the app shows one -- the menu bar duration (which then ticks every second rather than refreshing each minute), and the Report tab's totals, entry durations and start and end times.
- **Pause the device when locking it** (`pause_on_lock`, default on): whether locking the device also pauses it. It applies when quitting too — the app locks the cube on its way out either way, so it is not left running with nothing controlling it, and this setting decides only whether a pause goes out first. Read at the step that needs it rather than at launch, so changing it takes effect on the next lock.
- **Daily reset at** (`daily_reset_time`, default 3 AM): when each category's daily total rolls over. AM only, deliberately — a reset in the middle of the afternoon would cut a working day's accounting in half.
- **Battery warning at** (`low_battery_level`, default 10%): the battery percentage at or below which the menu bar activity text starts blinking red/white (see Status Indicators below). Once triggered it only clears again after the battery climbs 5 points above the threshold, so a reading wobbling around the threshold doesn't flicker the warning on and off.
- **Fetch history every** (`fetch_history_interval_seconds`, default 10 seconds, edited in whole minutes): how often the app asks the device for anything it hasn't seen, as a safety net behind the live flip notifications.
- **Ignore flips under** (`blip_time`, default 5 seconds, max 30, `0` disables): how short a segment has to be before it counts as the cube being turned past a face rather than time spent on it. Turning the cube to the face you want drags it across the others, and the device reports each pass-over as a real segment — measured ones run 0 to 3 seconds. The default matches the vendor protocol's own 5-second figure. A segment under the threshold is recorded in the device history as normal but gets no time entry, so it never reaches a report or your calendar. Lowering the value later brings previously-ignored segments back, since nothing was thrown away.

## Usage

### Basic Time Tracking

1. Flip your TimeFlip device to any face to start tracking that activity
2. The menu bar shows the current activity name, icon, and elapsed time
3. Flip to another face to switch activities
4. All completed sessions are automatically logged

### Manual Pause/Resume

- Click the left side of the menu bar item (icon + activity name) to open the dropdown menu, then select "Pause"/"Resume"
- Once paired, a single click on the **right side** of the item (the duration/indicator) toggles pause/resume directly, without opening the menu
- None of this works while the device is locked (see Locking the Device below) — locking disables pause/resume everywhere until you unlock it again

### Locking the Device

- **Double-click the right side** of the menu bar item, or select **Lock/Unlock** from the dropdown menu — both read the device's actual current lock state first, then flip it, so either one works as a true toggle
- **The lock always goes out; `pause_on_lock` only decides whether a pause goes first.** With it enabled and the device not already paused, locking pauses it first, whatever the device was doing beforehand. The order is the protocol's rather than a preference: a locked cube that is not paused goes on recording against whatever face is up, and it reports itself paused whatever its pause byte says, so the pause has to be confirmed *before* the lock is sent
- While locked, a red lock icon appears next to the pause/play indicator in the menu bar, so you can still tell at a glance whether the device is timing or paused underneath the lock
- Unlocking just removes the lock icon — it doesn't change the pause/running state either way
- While locked, pause/resume is disabled everywhere — the single-click toggle and the menu item both do nothing. Double-clicking to unlock is the only action that works

### Status Indicators

The activity name and duration text in the menu bar change color to reflect device state:

| Colour | Meaning |
|---|---|
| Green | A cube is doing the timing, and this is a live reading off it |
| Cyan | The app is doing the timing, with nothing paired. Also a live reading, of the other picture |
| Yellow | A paired cube has dropped. The last face and figure are still shown, because they are still worth seeing, but nothing about them can be confirmed |
| Red (the figure alone) | The category on show is over its daily limit |
| Blinking red (the category name alone) | Battery is at or below the low-battery threshold — see App Settings above |

Green and cyan are the pair that say **which of the two pictures you are looking at**: whether the cube
is the clock or the app is. The play/pause glyph between them takes neither colour and stays the menu
bar's own, because whether a clock is going means the same in both.

The limit colours the **figure** and not the name: the name is only which category this is, and
reaching a limit does not make it a different one. That also leaves the name free to carry the
low-battery flash, which alternates twice a second and only lets go once the charge is five points
clear of the threshold, so a reading wobbling around it does not flicker.

Yellow takes the whole line rather than sharing it: no limit red and no battery flash over the top,
both being colours left over from before the drop. A red lock badge is drawn before the play/pause
glyph while the cube is locked, rather than in place of it, so whether it is timing or stopped stays
readable underneath the lock.

If the connection drops (e.g. the laptop goes to sleep or the device goes out of range), the app retries automatically with increasing backoff, and also retries when the Mac wakes from sleep — you shouldn't need to manually reconnect. On wake, the text turns yellow immediately, then after a fixed 2-second pause the app attempts the reconnect (a deliberate delay so it's visibly obvious the retry actually ran, rather than happening so fast it's indistinguishable from the device having already been in range). See Troubleshooting below if it doesn't recover.

### Timing without a device

**With nothing paired, the app is the clock.** The Faces tab draws a play/pause control where the cube
would be, and clicking a category starts timing it — into the same `device_event` and `time_entry` rows
a cube writes, so reports and calendar sync do not know the difference. The right half of the menu bar
item still pauses, since there is a clock to stop.

It is not a mode you enter or leave. Whether the app follows a cube or is its own clock is read from
whether anything is paired, at the moment the question is asked — so pairing a cube makes the app
follow it from that moment, and Forget Device hands the clock back. Neither needs a restart.

If a paired cube cannot be found at startup, the app says so and offers **Retry** or **Stop Looking**.
Stop Looking stops the app hunting for it this launch; it does not unpair anything, so to time by hand
from there you forget the device.

### Viewing statistics

- The menu bar shows the current category's total **for today**, not this session's stopwatch — pick a
  category up again after lunch and it still shows the morning.
- The **Report** tab totals every category over a chosen day or span. Both ends of a stretch are clipped
  to the range, so two adjacent reports add up to the report over both, and a one-day report is exactly
  what the menu bar showed that day.
- A day here is **the app's own day**, `daily_reset_time` to the same time next day (3am by default),
  not a calendar midnight — so a session running past midnight stays on the day it started.

## Troubleshooting

### Device Won't Connect

- Ensure Bluetooth is enabled
- If the device doesn't show up in the scan results, try checking **"All Devices"** — the TimeFlip-only filter matches on advertised name/service, which isn't always reliable
- If your device is already connected to the official TimeFlip phone app, disconnect it there first (Settings > three dots > "Disconnect TimeFlip") — just turning off the phone's Bluetooth isn't enough, since the official app appears to set a private password on connect
- A device shown with strikethrough text failed the TimeFlip verification check and can't be clicked again this session — that's expected for genuinely different Bluetooth devices, not a bug
- If pairing fails with "Wrong PIN," the device isn't on the default `000000` password (likely because the official phone app, or a previous pairing from this app, set a custom one). There's no manual password field — recover via either the official app's "Disconnect TimeFlip" (if the device is still bound to a phone account) or a hard reset (remove and reinsert the coin-cell battery), both of which restore the factory default password
- Try resetting the device by removing and reinserting the battery
- Check Bluetooth permissions in System Preferences > Privacy & Security
- Check the terminal you launched the app from — every byte in both directions is printed there, and
  recorded in the `debug_log` table of `debug.sqlite` (in `~/Library/Application Support/Facet/`), which
  outlives the session and can be queried afterwards

### Signing in to Google fails

- There is no Client ID or Client Secret to get wrong: the app carries its own. If sign-in fails with
  the client missing, the build has no `Info.plist` — a bare `swift build` produces the executable
  without a bundle. Build with `scripts/run.sh`
- Try signing out and signing in again

### Events not syncing to Google

- Check the Google section on the **App** tab says Connected, and names a calendar
- **If macOS is prompting for Keychain access, or sync went quiet after a rebuild**: the build was
  ad-hoc signed, so the refresh token stored by the previous build is no longer readable. Nothing fails
  visibly, the sweep simply never runs. Build through `scripts/run.sh`, which signs with a real identity
  where there is one; see [google-oauth-setup.md](google-oauth-setup.md)
- An entry that failed is not queued anywhere — it is still `synced_to_google_calendar = 0`, and the
  next entry recorded carries it across along with its own. Connecting a calendar triggers the same
  sweep, which is what delivers a backlog recorded before anyone signed in
- The `sync` tag in `debug_log` says what each pass did, including which field of a read-back
  disagreed

### Menu Bar Not Updating

- If the text has turned yellow, the app has detected a dropped connection and is retrying automatically — this is expected (e.g. right after the laptop wakes from sleep, or the device briefly goes out of range) and should clear on its own within a few reconnect attempts
- If it is cyan, nothing is paired and the app is timing by hand. That is not a fault; see
  [Timing without a device](#timing-without-a-device)
- Check the Device tab's Connection row, which says which of the three states it is in
- Try manually pausing and resuming
- Restart the application
