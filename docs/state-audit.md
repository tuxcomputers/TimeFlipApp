# State Audit

Every fact this app branches on, what it is really a fact about, where the truth for it lives, and every
name it currently goes by.

## What this is for

A branch is only correct if it is asking the right question. This app has 1,152 lines carrying a
conditional and no single place saying what the questions are, so the same fact is asked under several
names, and two names have come to mean two different facts. Both have already produced bugs that shipped
green: on 2026-08-27 a spent `daily_limit` was bypassed by the status item because three of the four
places that consult the limit ask it about the app's own clock, and a cube leaves that `.idle` however
busy it is.

This file is the register. It is a description of what is there, not a proposal: no code was changed to
produce it.

## How to read an entry

- **Question** is the fact in one sentence, phrased as what a branch actually wants to know.
- **Truth** is where the answer really lives. A database column, a radio property, or an in-memory flag,
  and it matters which: a column is read at the point of use per the first rule in `CLAUDE.md`, a radio
  property is only as fresh as the last question asked of the cube, and an in-memory flag is a claim the
  app is making about itself.
- **Names** is every identifier the fact travels under today, including parameter labels.
- **Traps** is where the obvious reading is wrong.

Counts in brackets are occurrences of the identifier across `Sources/FacetApp/`, doc comments included.

---

## 1. Launch and process

### 1.1 Which of the two things this launch is

- **Question:** is this app following a cube, or is it its own clock?
- **Truth:** `LaunchMode`, decided once at startup from `setting.paired`, then fixed for the process.
- **Names:** `LaunchMode.isManual` (6), `isTimingByHand` (21), `isManualMode` (8), `launchMode.isManual`
- **Read by:** `TimingReadout`, `DeviceReconnector` (twice, as a guard on following), `DeviceInfoRules.connection`,
  `SettingsWindowController`, `DevicePane`
- **Traps:**
  - This is deliberately *not* the same fact as `paired`. A manual launch can pair a cube afterwards, and a
    device launch can lose one. `DeviceInfoRules.connection` is the one place that says so out loud.
  - `StatusItemClickRouter` and `PauseMenuRules` never receive it. They infer the mode from
    `timing == .idle && isCubeConnected` instead, which is a second answer to a question that already has a type.

### 1.2 Developer mode

- **Question:** is this a developer build, with debug printing and the shorter timer floors?
- **Truth:** `DeveloperMode.isEnabled`
- **Names:** `DeveloperMode.isEnabled` , `isDeveloperBuild` (3, in `HistoryTimer.interval`)
- **Read by:** every `DeveloperMode.debugPrint` call site, `DeveloperConfigFile`, `HistoryTimer.interval`,
  `main.swift` for the database badge and the debug log

### 1.3 Which database

- **Question:** production or test?
- **Truth:** `DatabaseEnvironment.read(from:)`, over `setting.database.type`
- **Names:** `DatabaseEnvironment` with cases `production` and `test`
- **Read by:** `main.swift` only, to choose the file and the badge

### 1.4 Quit in progress

- **Question:** is the app shutting down deliberately?
- **Truth:** `setting.connection.quit_request` (a timestamp, written by `DevicePairingRecorder`), plus
  `QuitSequence`'s own progress
- **Names:** `quit_request`, `willTerminate`
- **Traps:** `quit_request` and `connection_lost` are two claims, not one. The quit clears
  `connection_lost` so that a deliberate shutdown is never read back as a link that dropped.

---

## 2. Pairing and the link

### 2.1 A cube is paired

- **Question:** does this app have a cube at all?
- **Truth:** `setting.paired.paired`
- **Names:** `isPaired` (62), `isCubePaired` (3, on `TimingReadout`), `paired`, `settings.flag("paired", field: "paired")`
- **Read by:** `DeviceReconnector.follow`, `DeviceInfoRules` (name, connection, battery), `DevicePairingRules.allowsForget`,
  `TimingReadout`, `LaunchMode.decided`

### 2.2 A cube is reachable right now

- **Question:** is there a live link to send a command down?
- **Truth:** `BluetoothRadio.connectedDevice != nil`. `setting.connection.connected` is the written record of it.
- **Names:** `isConnected` (61), `isCubeConnected` (9), `isDeviceReachable` (14), `isLive`,
  `connectedDevice != nil` (9), `connection.connected`
- **Read by:** `CubeLock` (three guards), `CubeLockRules.isEnabled`, `PauseMenuRules.target`,
  `StatusItemClickRouter.action`, `FacesTabRules`, `DeviceInfoRules.isLive`, `HistoryTimer.hasSomethingToFollow`,
  `ForcedPauseWatch`, `DeviceReconnectRules`
- **Traps:**
  - **This is the connection, not the pairing.** A paired cube in another room can be neither paused nor locked.
  - `isDeviceReachable` on a `TimingReadout.Reading` is the same fact, but the reading deliberately keeps
    `deviceFace` after the link drops: the face is worth drawing, and nothing may be sent to it. `deviceFace`
    says what to draw, `isDeviceReachable` says what may be done about it.
  - A reading with no `deviceFace` forces `isDeviceReachable` to `false` in the initialiser, whatever the caller passed.

### 2.3 The radio is scanning

- **Question:** is a scan running?
- **Truth:** `BluetoothRadio.isScanning`
- **Names:** `isScanning` (24), `wantsToScan` (6)
- **Traps:** two flags, not one. `wantsToScan` is the intent, kept across a powered-off radio so the scan
  resumes when Bluetooth comes back; `isScanning` is whether one is actually running now.

### 2.4 The app is reaching for its cube

- **Question:** is a reconnect attempt under way?
- **Truth:** `BluetoothRadio.isReaching`, derived as `reaching != nil || attempt != nil`
- **Names:** `isReaching` (24)
- **Read by:** `DeviceReconnectRules.shouldAttempt`, `DevicePairingRules.allowsForget`

### 2.5 A cube-not-found prompt is on screen

- **Question:** is the app waiting for the user to answer the retry offer?
- **Truth:** `DeviceReconnector.isAwaitingAnswer`
- **Names:** `isAwaitingAnswer` (7)

### 2.6 A disconnect was deliberate

- **Question:** did the app drop this link on purpose, or did it fail?
- **Truth:** `BluetoothRadio.isDisconnectingDeliberately`
- **Names:** `isDisconnectingDeliberately` (10)

### 2.7 A factory reset is running

- **Question:** has the app sent `0xFF` and not yet seen the cube come back?
- **Truth:** two independent flags. `BluetoothRadio.isResetting` is `resetConfirmation != nil`;
  `DeviceLogin.isResetting` is its own stored `Bool`.
- **Names:** `isResetting` (12), `resetConfirmation`
- **Traps:** the same name on two types, holding two flags that are set and cleared separately. Nothing
  keeps them in step.

---

## 3. In-flight work: the "busy" flags

Each of these guards a re-entrancy window. They are separate facts about separate conversations, and they
are listed together because they share a shape rather than a meaning.

| Question | Truth | Names |
| --- | --- | --- |
| Is a BLE command awaiting its answer? | `DeviceLogin.isBusy`, derived as `pendingCommand != nil \|\| pendingStatus != nil` | `isBusy` (4) |
| Is a history fetch running? | `HistoryIngestor.isRefreshing` | `isRefreshing` (7) |
| Is a forced pause on the wire? | `ForcedPauseWatch.isSending` | `isSending` (5) |
| Is a calendar sweep running? | `CalendarSync.isSweeping` | `isSweeping` (4) |
| Is a command read-back outstanding? | `DeviceLogin.isReadingBack` | `isReadingBack` (8), `pendingReadBack` |
| Is device info being read? | `DeviceLogin.isReadingInfo` | `isReadingInfo` (6) |
| Are the double-tap registers being read? | `DeviceLogin.isAskingAboutTaps` | `isAskingAboutTaps` (8) |
| Is the battery being followed? | `DeviceLogin.isFollowingBattery` | `isFollowingBattery` (5) |
| Is a sign-in running? | `AppSettingsPane.isSigningIn` | `isSigningIn` (13) |

**Trap on `isSending`:** its comment records why the claim cannot stand in for it. "Claimed face, table says
running" is also what a hand-resume looks like, and that case must pause again, so only knowing a command is
in flight tells the two apart.

---

## 4. The cube's own condition

### 4.1 The cube is locked

- **Question:** is the cube frozen on its face, ignoring everything but an unlock?
- **Truth:** `BluetoothRadio.cubeStatus?.isLocked`, from the `0x10` read-back
- **Names:** `isLocked` (63, shared, see the collision below), `isCubeLocked` (11), `status.isLocked`
- **Read by:** `CubeLockRules.title`, `PauseMenuRules.target`, `CubeLock`, `ForcedPauseWatch`, `StatusItemTitle`
- **Traps:** `nil` means nobody has asked. `PauseMenuRules` and `CubeLockRules` both treat unknown as
  unlocked, deliberately: an item enabled and then refused says why in the log, while one greyed out for a
  lock that is not there offers no way to find out it was wrong.

### 4.2 The cube is stopped

- **Question:** is the cube's own clock stopped?
- **Truth:** two answers, both legitimate. `device_event.paused` on the open row is the cube's history talking;
  `BluetoothRadio.cubeStatus?.isPaused` is its live `0x10` answer.
- **Names:** `isPaused` (74, shared, see the collision below), `isCubePaused` (13), `isDevicePaused` (8),
  `deviceIsPaused`, `paused` (the column), `status.isPaused`
- **Read by:** `CubeLock.togglePause`, `PauseMenuRules` (target and title), `StatusItemClickRouter.action`,
  `ForcedPauseWatch`, `TimingView`, `StatusItemTitle`, `TimingReadout`
- **Traps:**
  - **A locked cube reports itself paused whatever its pause byte says.** `DeviceCommandRules` encodes this as
    `isPaused: locked ? true : paused`. A pause confirmed after a lock proves nothing, so pause is confirmed first.
  - "Is this cube paused" and "is this total moving" are different questions. See 5.2.

### 4.3 Which face the cube is resting on

- **Question:** which of the twelve is up?
- **Truth:** `device_event.device_face` on the open row is the record; `BluetoothRadio.currentFace` is the
  live notification.
- **Names:** `deviceFace` (on the reading), `currentFace` (on the radio), `device_face` (the column),
  `openFace` (on `ForcedPauseWatch`), `face`
- **Traps:** faces 1 to 12 are the cube's; 13 and 14 are the app's own, used by manual mode.
  `ManualFace.isTheApps` is the test, and `ForcedPauseWatch` filters at the closure so the decision only ever
  sees a face a cube reported.

### 4.4 Battery

- **Question:** how much charge, and is it low enough to say so?
- **Truth:** `BluetoothRadio.batteryPercent`; the threshold is `setting.low_battery_level.percent`
- **Names:** `batteryPercent`, `percent`, `isLow` (17), `isBlinkOn` (11), `isFollowingBattery` (5)
- **Traps:** `isLow` is latched in `LowBatteryWatch`, not recomputed per read, so it does not chatter across
  the threshold. `isBlinkOn` is a display phase, not a fact about the cube.

### 4.5 What the cube is asking for

- **Question:** has the cube reported a sync requirement or a hardware fault?
- **Truth:** `DeviceSystemStateRules.State`, with `Sync` (`ok`, `factoryReset`, `timeRequired`,
  `faceColoursRequired`, `ledBrightnessRequired`, `blinkIntervalRequired`, `taskParametersRequired`,
  `autoPauseRequired`, `unknown`) and `Hardware` (`ok`, `accelerometer`, `flash`, `accelerometerAndFlash`, `unknown`)
- **Read by:** `main.swift` acts on `.factoryReset` only; the rest is recorded and not acted on
- **Traps:** history lives in flash, so a cube reporting a flash fault records nothing, which from the outside
  looks exactly like a cube that was reset.

### 4.6 Double tap

- **Question:** is double-tap-to-pause on?
- **Truth:** `setting.double_tap_settings.enabled`, with `latency`, `limit` and `window` beside it
- **Names:** `isDoubleTapEnabled` (8)

---

## 5. Timing

### 5.1 What the app's own clock is doing

- **Question:** is this app running a session of its own?
- **Truth:** `TimingState`, with cases `idle`, `running`, `paused`, built by `ManualTimerRules.state(categoryID:isRunning:)`
- **Names:** `state`, `timing`, `TimingState`, `isRunning` (5)
- **Traps:** **`state` is `.idle` for the whole time a cube is followed.** The app runs no clock of its own
  then. Asking `state == .running` to mean "something is being timed" is the exact fault run 116 found:
  `DailyLimitWatch` asked it in three places and never armed against a cube.

### 5.2 The figure on screen is moving

- **Question:** is the number going up, whoever is doing the measuring?
- **Truth:** `TimingReadout.Reading.isCounting`, answered by `DayTotal`
- **Names:** `isCounting` (25), `isTicking` (4, on the two view controllers)
- **Read by:** `DailyLimitWatch` (three sites), `MenuBarController`, `SettingsWindowController`
- **Traps:** different from both 4.2 and 5.1. A cube that has flipped but whose history has not been fetched
  still names its new face, and the newest row for that face may be a stretch that ended an hour ago, so
  "paused" and "counting" are not complements. `isTicking` is about whether a repaint timer is armed, not
  about the cube.

### 5.3 There is an open segment

- **Question:** is a stretch of time still being measured?
- **Truth:** `device_event.finalised = 0`, reached through `DeviceEventRecorder.openSegment()`
- **Names:** `openSegment()`, `isOpen` (5), `isFinalised` (6), `finalised` (the column), `latestSegment`
- **Traps:** `isOpen` on `DeviceEventRecorder.Outcome` describes what a write just did, not what the table
  now holds.

### 5.4 Whose segment it is

- **Question:** did this app measure this stretch, or did a cube?
- **Truth:** the face number. `ManualFace.isTheApps(face)` is `face > 12`.
- **Names:** `ManualFace.isTheApps` (6), `highestDeviceFace`
- **Traps:** this is what decides whether the wall clock may write a duration. A cube's duration comes from
  its history and nothing else, so growing a cube's row from this machine's clock overwrites a measurement
  with a guess.

### 5.5 The history timer is armed

- **Question:** is the periodic fetch running?
- **Truth:** `HistoryTimer.holder.timer != nil`, reported as `scheduledSeconds`
- **Names:** `timer != nil`, `scheduledSeconds`, `hasSomethingToFollow` (7)
- **Traps:** the timer stops itself when there is nothing to follow, so every path that starts timing has to
  call `resumeIfStopped`. `hasSomethingToFollow` is an open segment **or** a connected cube, which is why a
  connected cube's timer never stops, and why `historyIngestor.onChanged` gets away with not resuming it.

---

## 6. Face, category and the daily limit

### 6.1 A face holds a category

- **Question:** does this face mean anything yet?
- **Truth:** `face.category_id`
- **Names:** `hasCategory` (11), `categoryID(forFace:)`, `category`
- **Read by:** `ForcedPause` (the whole first rule is this question), `TimingReadout`, `FacesTabRules`

### 6.2 A face is locked

- **Question:** is this face refusing to be reassigned?
- **Truth:** `face.locked`
- **Names:** `isFaceLocked` (9), `isLocked` (shared with 4.1, see the collision below), `locked`
- **Read by:** `FacesTabRules.assignment`, `CategoryEditRules.editRefusal`, `TimingView`

### 6.3 A category is active

- **Question:** is this category still in use, or retired?
- **Truth:** `category.active`
- **Names:** `isActive` (42, but most occurrences are AppKit's `NSLayoutConstraint.isActive`), `active`
- **Traps:** the name collides with Auto Layout throughout the view files. Read the receiver.

### 6.4 A category has a daily limit at all

- **Question:** is there a budget on this category?
- **Truth:** `category.daily_limit`, in minutes, where `0` means no limit
- **Names:** `dailyLimitMinutes`, `daily_limit`, `limitMinutes`

### 6.5 The limit is spent

- **Question:** has the category on show used its budget for the day?
- **Truth:** `DailyLimitEnforcement.isReached(totalSeconds:limitMinutes:)`, over the day window from `DayTotal`
- **Names:** `isLimitReached` (43), `isReached` (12), `dailyLimit.isReached`
- **Read by:** `ManualTimerRules.isClickable`, `PauseMenuRules.target`, `StatusItemClickRouter.action`,
  `CubeLock.startingIsRefused`, `StatusItemTitle`, `TimingView`, `SettingsWindowController`
- **Traps:**
  - **Four separate expressions decide this, not one.** `ManualTimerRules` asks
    `state == .paused && isLimitReached`; `PauseMenuRules` asks `isLimitReached && isCubePaused == true`;
    `StatusItemClickRouter` asks the same with the action folded in; `CubeLock` asks the bare closure. Each
    had to be found and taught separately, and two of them were missing until 2026-08-27.
  - `isReached` names three different things: a static function on `DailyLimitEnforcement`, an instance
    method on it, and a computed property on `DailyLimitWatch`.
  - Every one of these paths refuses only a **start**. Stopping is never refused, because a limit that
    trapped somebody into recording time would be the opposite of what it is for.

### 6.6 The limit is holding a pause

- **Question:** is the cube stopped *because* of the limit, as opposed to for any other reason?
- **Truth:** `DailyLimitEnforcement.isPausedByLimit`
- **Names:** `isPausedByLimit` (8), `isHoldingAPause` (3)
- **Read by:** `ForcedPauseWatch.limitIsHolding`, so assigning a category to a face cannot lift a hard limit

---

## 7. History

### 7.1 Where the cube is up to

- **Question:** which event number has the app already recorded?
- **Truth:** `device_event.event_number`, read out of the table on every refresh
- **Traps:** a factory reset restarts the cube's counter, so `MAX(event_number)` alone is not a cursor. There
  is deliberately nothing to clear on reset: the resume position is read from the table and checked against
  what the cube can reach.

### 7.2 What kind of frame this is

- **Question:** is this frame a single event, a stream member, or the end?
- **Truth:** `DeviceHistoryRules.isEndOfStream(frame)`; the request carries `isSingleFrame`
- **Names:** `isEndOfStream` (4), `isSingleFrame` (8), `isNoSuchEvent` (2)
- **Traps:** a `0x01` reply arrives as a **read** and never as a notification. Waiting on a notification
  there reliably times out against real hardware.

---

## 8. Google and calendar sync

- **Account state:** `GoogleAccountRules.State` with `notConnected`, `signedOut`, `unverified`, `connected`,
  `expired`, `unreachable`, `unreadable`
- **Credentials present:** `hasCredentials` (10), `googleCredentialsAvailable`
- **Signing in:** `isSigningIn` (13)
- **Sweep running:** `isSweeping` (4)
- **Calendar gone:** `isCalendarGone` (2), `CalendarGone`
- **Nothing to sync into, already said:** `hasReportedNothingToSyncInto` (4)
- **Refresh token present:** `tokens.refreshToken != nil`

---

## 9. Settings window and list UI

These are view state. They are listed because they appear in branches, not because anything outside the
window should read them.

| Question | Truth | Names |
| --- | --- | --- |
| Which tab is on show? | `SettingsTab` (`faces`, `categories`, `report`, `app`, `device`) | `SettingsTab`, `selectedTabViewItem` |
| Is a section folded? | `PanelSection.isExpanded` / `DisclosureRow` | `isExpanded` (52) |
| Is a field being edited? | `CategoryCreateControl.isEditing` | `isEditing` (29) |
| Is a row selected? | per-list | `isSelected` (19) |
| Is a control usable? | per-control | `isEnabled` (72), `isClickable` (10), `isSelectable` (5), `isButtonEnabled` (2) |
| Is a view drawn? | AppKit | `isHidden` (41), `isVisible`, `isOnScreen` (3) |
| Is a repaint timer armed? | `tick != nil` on both controllers | `isTicking` (4) |

**Trap:** an open Settings window is the one licensed holder of a value rather than a re-reader of it, under
the five conditions in `CLAUDE.md`. That licence covers settings, not lists: which rows belong in a list is a
different question from what a value is, and it is re-read.

---

## 10. Report tab

| Question | Truth | Names |
| --- | --- | --- |
| Is this day in the shown month? | `ReportCalendarGrid` | `isInMonth` (3) |
| Is this day an endpoint of the range? | `ReportCalendarGrid` | `isRangeStart` (4), `isRangeEnd` (4) |
| Is this the same day / month? | `ReportCalendarGrid` | `isSameDay` (8), `isSameMonth` (2) |
| Is this day emphasised? | `ReportCalendar` | `isEmphasised` (6) |
| How is the list sorted? | `ReportSortRules` | `Direction`, `Column` |
| What range is shown? | `ReportRangeRules` | `Order` |

---

## Collisions: one name, two facts

These are the ones that can be read wrong without anything failing.

### `isLocked` is both the cube and a face

`CubeLockRules.title(isLocked:)` is the cube being frozen (4.1). `CategoryEditRules.editRefusal(facesHolding:
[(face: Int, isLocked: Bool)])` and `FaceStore.isLocked(face:)` are a face refusing reassignment (6.2). Two
unrelated facts, one word, and the only thing telling them apart is the receiver.

### `isPaused` is both the cube's pause byte and "not counting"

`CubeLock.isPaused` and `PauseMenuRules(isCubePaused:)` mean the cube's own stopped state (4.2).
`DailyLimitEnforcement.evaluate(isPaused:)` is fed `!reading.isCounting` from `DailyLimitWatch`, which is the
figure not moving (5.2), for either clock. **Its own doc comment still describes the first fact**: "whether
the cube is paused *now*, as last reported by a history frame". The behaviour is deliberate and correct after
the run 116 fix; the name and the comment were not updated with it.

### `isResetting` is two flags

`BluetoothRadio.isResetting` (`resetConfirmation != nil`) and `DeviceLogin.isResetting` (a stored `Bool`) are
set and cleared independently. See 2.7.

### `isActive` is mostly Auto Layout

`category.active` (6.3) shares the name with `NSLayoutConstraint.isActive`, which is the large majority of the
42 occurrences.

### `isReached` is three members

A static function, an instance method and a computed property. See 6.5.

---

## Aliases: one fact, many names

| Fact | Names it goes by | Section |
| --- | --- | --- |
| The cube is stopped | `isPaused`, `isCubePaused`, `isDevicePaused`, `deviceIsPaused`, `paused`, `status.isPaused` | 4.2 |
| The cube is reachable | `isConnected`, `isCubeConnected`, `isDeviceReachable`, `isLive`, `connectedDevice != nil`, `connection.connected` | 2.2 |
| The cube is locked | `isLocked`, `isCubeLocked`, `status.isLocked` | 4.1 |
| This launch is manual | `LaunchMode.isManual`, `isTimingByHand`, `isManualMode` | 1.1 |
| A cube is paired | `isPaired`, `isCubePaired`, `paired` | 2.1 |
| The limit is spent | `isLimitReached`, `isReached` | 6.5 |
| The limit is holding a pause | `isPausedByLimit`, `isHoldingAPause` | 6.6 |
| A face is locked | `isFaceLocked`, `isLocked`, `locked` | 6.2 |
| Which face is up | `deviceFace`, `currentFace`, `device_face`, `openFace`, `face` | 4.3 |

---

## Facts that have no single reader

Recorded because a branch that wants them has to assemble them today.

- **"Something is being timed at all", either clock.** The nearest thing is `isCounting`, which is about the
  figure moving. `hasSomethingToFollow` is the closest to an app-wide answer and it belongs to `HistoryTimer`.
- **"The clock may be started."** Spread across `ManualTimerRules.isClickable`, `PauseMenuRules.target`,
  `StatusItemClickRouter.action` and `CubeLock.startingIsRefused`, in four different shapes. See 6.5.
- **"Which clock a stop should go to."** Decided inline in `main.swift`'s `stopTiming` from the open
  segment's face.
- **The mode, at the two routers.** Inferred from `timing == .idle && isCubeConnected` rather than read from
  `LaunchMode`. See 1.1.

---

## What is deliberately not state

- **The reference tables.** `icon`, `colour` and `event_type` are seeded by the DDL, never written by the app,
  and fixed for the life of a launch. They may be held in memory. Nothing else may.
- **Derived display values.** Titles, glyph names, colours and accessibility labels are computed from the facts
  above at draw time and are not facts themselves.
- **Callback identity.** `onChanged`, `onFace`, `onCubeStatus` and the rest are wiring, not state.

---

## The sweep: what this codebase renames to

The name from `docs/state-reference.md` on the left, and every spelling in this codebase that becomes it on
the right. This records the work against the code as it stands at the top of this file. A name that appears
in neither column is already correct.

| Name to use | Names that become it |
| --- | --- |
| `batteryPercent` | `percent`, the reading in `DeviceInfoRules.battery`. The warning threshold beside it stays `batteryWarningPercent`, being a different fact |
| `cubeFace` | `deviceFace`, `currentFace`, `openFace` |
| `cubeHardwareState` | `Hardware` |
| `cubeLockState` | `isLocked` (the cube), `isCubeLocked` |
| `cubePauseState` | `isPaused` (the cube), `isCubePaused`, `isDevicePaused`, `deviceIsPaused` |
| `cubeSyncState` | `Sync` |
| `dailyLimitMinutes` | `limitMinutes` |
| `googleAccountState` | `GoogleAccountRules.State` |
| `hasGoogleCredentials` | `hasCredentials`, `googleCredentialsAvailable` |
| `hasGoogleIdentity` | `hasIdentity` |
| `hasReachedCube` | `hasReachedTheCube` |
| `hasReportedMissingCalendar` | `hasReportedNothingToSyncInto` |
| `historyFrameState` | `isEndOfStream`, `isNoSuchEvent` |
| `isAnotherSweepWanted` | `wantsAnotherPass` |
| `isAppFace` | `isTheApps` |
| `isBatteryLow` | `isLow` |
| `isCalendarSweeping` | `isSweeping` |
| `isCategoryActive` | `isActive`, where it is ours and not Auto Layout |
| `isCommandInFlight` | `isBusy` |
| `isCounting` | `isPaused`, where it meant the figure not moving. **Inverted** |
| `isCubeConnected` | `isConnected`, `isCubeConnected`, `isDeviceReachable`, `isLive` |
| `isCubePaired` | `isPaired` |
| `isDeveloperMode` | `DeveloperMode.isEnabled`, `isDeveloperBuild` |
| `isFaceLocked` | `isLocked` (a face) |
| `isFactoryResetRunning` | `isResetting`, both flags |
| `isForcedPauseSending` | `isSending` |
| `isHistoryFetching` | `isRefreshing` |
| `isLimitHoldingPause` | `isPausedByLimit`, `isHoldingAPause` |
| `isLimitReached` | `isReached` |
| `isManualMode` | `isTimingByHand`, `LaunchMode.isManual` |
| `isReachingForCube` | `isReaching` |
| `isReadingDeviceInfo` | `isReadingInfo` |
| `isReadingDoubleTap` | `isAskingAboutTaps` |
| `isRepaintTicking` | `isTicking` |
| `isScanWanted` | `wantsToScan` |
| `isSegmentOpen` | `isFinalised` was **not renamed**: it is a row's own column, like a segment's `isPaused`, and a finalised row saying it was a pause is history rather than what the cube is doing now. The state itself is `events.openSegment() != nil`, which had no boolean carrier |
| `isSingleFrameRequest` | `isSingleFrame` |
| `isSortAscending` | `Direction` |
| `settingsTabState` | **not renamed**: which tab is on show is AppKit's `selectedTabViewItem`, and `tabOnOpen` and `select(_ tab:)` name a tab value rather than the current one, so there was no state variable here |
| `sortColumnState` | `Column`, on the report sort |
| `timingState` | `state`, `timing`, where either is the app's own clock |

**Two of these cannot be done by search and replace.** `isLocked` and `isPaused` each mean two different
facts depending on the file, so every occurrence is read before it is changed. The collisions section above
says where each one lands.

**One flips as well as renaming.** `isCounting` replaces an inverted `isPaused` in
`DailyLimitEnforcement.evaluate`. The 36 fixtures that pass with every call site inverted are what says the
behaviour was already right and only the name was wrong.

---

## Keeping this current

Add a state here when a branch first needs it, in the same change that adds the branch. If a fact turns out to
already be listed under another name, use the listed name rather than adding a synonym: the alias table above is
a record of what happens otherwise.
