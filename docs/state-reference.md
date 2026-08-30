# State Reference

The name of every state in this app. **One state, one name, used everywhere.**

A second spelling of a state listed here is not an alternative, it is a rename waiting to happen.

Its companion is `docs/state-audit.md`: the snapshot of what the code calls these things today, and the sweep
list that maps every current spelling onto the name given here. Section numbers match between the two files.

## The convention

- **A state that can only be true or false is `is<Name>` or `has<Name>`**, whichever is the English.
  `is<Name>` for a state the subject is *in*: `isCubeConnected`, `isManualMode`, `isCubePaired`, `isScanning`.
  `has<Name>` for something the subject *possesses* or *has already done*: `hasCategory`,
  `hasGoogleCredentials`, `hasReportedWriteFailure`. The test is which one reads as English: `hasPaused` is
  wrong because paused is a state, not a possession, and `isCategory` is wrong because a category is a thing
  a face holds, not a state it is in.
- **A state that can be more than true or false is `<name>State`.** `timingState`, `cubeLockState`. The type it
  is carried in takes the same name in Pascal case: `TimingState`, `CubeLockState`.
- **The name carries its subject.** `isLocked` obeys the convention and still means two unrelated facts, the
  cube frozen on its face and a face refusing reassignment. So `cubeLockState` and `isFaceLocked`, never
  `isLocked` twice.
- **No exceptions, including where the owning type repeats the subject.** `HistoryIngestor.isHistoryFetching`
  reads as a stutter, and that is the price of the value having one name wherever it is passed.

Two rules follow from the convention that are not obvious, and most of the renames below come from them.

**An optional Bool is three-valued, unless the third value is absence.** `Bool?` holds three answers, so it is
a `<name>State`. But `nil` does two different jobs here and only one is a state. Where `nil` means *nobody has
asked the cube yet*, that is a real third answer the app already branches on, so it becomes an explicit
`unknown` case. Where `nil` means *there is no such thing to ask about*, as in a face number that is not a
face, that is a failed lookup, the name stays `is<Name>`, and the absence is handled where the lookup is.

**A two-valued enum is a boolean.** The convention is about the fact, not the storage.

**Timing by hand is not a state of its own** (2026-08-29). `isManualMode` is `!isCubePaired`, read from the same row
at the same moment, so the two rows above are one fact under two names and the second is kept only because it reads
better where the question is "am I the clock". Nothing may hold it: it was a `LaunchMode` decided once at startup,
which could not move while the row under it did, and keeping the two in step cost a restart after every pair, forget
and reset. What is left of the old mode is `hasStoppedLooking`, which is a different fact -- whether this launch has
given up hunting for a cube it still has -- and now says so in its own name.

---

## 1. Launch and process

| Name | Values | Truth |
| --- | --- | --- |
| `isManualMode` | true / false | `setting.paired.paired`, read at the point of use: it **is** `!isCubePaired` |
| `isDeveloperMode` | true / false | `DeveloperMode` |
| `isTestDatabase` | true / false | `DatabaseEnvironment`, from `setting.db_type.type` |
| `isQuitting` | true / false | `setting.connection.quit_request`, plus `QuitSequence` progress |

## 2. Pairing and the link

| Name | Values | Truth |
| --- | --- | --- |
| `isCubePaired` | true / false | `setting.paired.paired` |
| `isCubeConnected` | true / false | `BluetoothRadio.connectedDevice != nil` |
| `isLinkSettled` | true / false | `FaceColourSync.isLinkSettled`, set by `BluetoothRadio.onCubeSettled` |
| `isScanning` | true / false | `BluetoothRadio.isScanning` |
| `isScanWanted` | true / false | `BluetoothRadio.wantsToScan` |
| `isReachingForCube` | true / false | `BluetoothRadio.isReaching` |
| `isAwaitingAnswer` | true / false | `DeviceReconnector.isAwaitingAnswer` |
| `hasStoppedLooking` | true / false | `DeviceReconnector.hasStoppedLooking`, per launch |
| `isDisconnectingDeliberately` | true / false | `BluetoothRadio.isDisconnectingDeliberately` |
| `isFactoryResetRunning` | true / false | today two separate flags |

`isCubeConnected` is the connection, not the pairing: a paired cube in another room can be neither paused nor
locked. `isDeviceReachable` folds into it. The reading keeps `cubeFace` after a link drops because the face is
worth drawing, and this is the separate question of what may be sent.

`isLinkSettled` is a third question again, and it is not `isCubeConnected` said later. The connection turns true
several round trips before the login has finished asking the cube its own questions, and until it has, the command
channel belongs to the login: the `0x17` read it has outstanding does not set `isCommandInFlight`, so a command sent
in that window is written over it rather than refused. So `isCubeConnected` is whether there is a cube to send to and
this is whether it may be sent to yet. Measured on 2026-08-28: over 26 connects the cube answered the systemState read
about 480ms before the login settled, every time.

`isFactoryResetRunning` is one fact currently held as two flags set and cleared independently. The sweep gives
it one name; whether it should also be one flag is a code question, not a naming one.

## 3. In-flight work

| Name | Truth |
| --- | --- |
| `isCommandInFlight` | `DeviceLogin.isBusy` |
| `isHistoryFetching` | `HistoryIngestor.isRefreshing` |
| `isForcedPauseSending` | `ForcedPauseWatch.isSending` |
| `isCalendarSweeping` | `CalendarSync.isSweeping` |
| `isAnotherSweepWanted` | `CalendarSync.wantsAnotherPass` |
| `isReadingBack` | `DeviceLogin.isReadingBack` |
| `isReadingDeviceInfo` | `DeviceLogin.isReadingInfo` |
| `isReadingDoubleTap` | `DeviceLogin.isAskingAboutTaps` |
| `isFollowingBattery` | `DeviceLogin.isFollowingBattery` |
| `isSigningIn` | `AppSettingsPane.isSigningIn` |

## 4. The cube's own condition

| Name | Values | Truth |
| --- | --- | --- |
| `cubeLockState` | `unknown` / `locked` / `unlocked` | `BluetoothRadio.cubeStatus?.isLocked` |
| `cubePauseState` | `unknown` / `paused` / `running` | `device_event.paused` on the open row, or `cubeStatus?.isPaused` live |
| `cubeFace` | 1 to 12, or none | `device_event.device_face` on the open row; `BluetoothRadio.currentFace` live |
| `batteryPercent` | 0 to 100, or none | `BluetoothRadio.batteryPercent` |
| `batteryWarningPercent` | 1 to 20 | `setting.low_battery_level.percent` |
| `isBatteryLow` | true / false | `LowBatteryWatch.isLow`, latched |
| `isBlinkOn` | true / false | `LowBatteryWatch` display phase |
| `cubeSyncState` | `ok`, `factoryReset`, `timeRequired`, `faceColoursRequired`, `ledBrightnessRequired`, `blinkIntervalRequired`, `taskParametersRequired`, `autoPauseRequired`, `unknown` | `DeviceSystemStateRules.Sync` |
| `cubeHardwareState` | `ok`, `accelerometer`, `flash`, `accelerometerAndFlash`, `unknown` | `DeviceSystemStateRules.Hardware` |
| `isDoubleTapEnabled` | true / false | `setting.double_tap_settings.enabled` |

`cubeLockState` and `cubePauseState` are the two largest changes here. Both are `Bool?` today with `nil`
meaning nobody has asked, and both are read as `== true`, a comparison that looks like a mistake and is in
fact the whole "unknown counts as unlocked" decision. As three cases the branch says what it means.

`cubePauseState` carries a trap no name can fix: a locked cube reports itself paused whatever its pause byte
says, so a pause confirmed after a lock proves nothing and pause is confirmed first.

## 5. Timing

| Name | Values | Truth |
| --- | --- | --- |
| `timingState` | `idle` / `running` / `paused` | `ManualTimerRules.state(categoryID:isRunning:)` |
| `isCounting` | true / false | `TimingReadout.Reading.isCounting`, answered by `DayTotal` |
| `isRepaintTicking` | true / false | `tick != nil` on both view controllers |
| `isSegmentOpen` | true / false | `events.openSegment() != nil`, over `device_event.finalised = 0` |
| `isAppFace` | true / false | `face > 12` |
| `isHistoryTimerArmed` | true / false | `HistoryTimer.holder.timer != nil` |
| `hasSomethingToFollow` | true / false | an open segment or a connected cube |

`timingState` already has the right name and is the model for the rest. It is also the one most often asked
wrong: it is `idle` for the whole time a cube is followed, because the app runs no clock of its own then. A
branch that wants "something is being timed" wants `isCounting`.

`isAppFace` rather than `isManualFace`, so it cannot be misread as being about `isManualMode`. The faces are
the app's own whichever mode the launch is in.

## 6. Face, category and the daily limit

| Name | Values | Truth |
| --- | --- | --- |
| `hasCategory` | true / false | `face.category_id` |
| `isFaceLocked` | true / false | `face.locked` |
| `isCategoryActive` | true / false | `category.active` |
| `dailyLimitMinutes` | 0 or more, where 0 is no limit | `category.daily_limit` |
| `isLimitReached` | true / false | `DailyLimitEnforcement.isReached(totalSeconds:limitMinutes:)` |
| `isLimitHoldingPause` | true / false | `DailyLimitEnforcement.isPausedByLimit` |

`isFaceLocked` stays a boolean even though `FaceStore.isLocked(face:)` returns `Bool?`: there `nil` means the
number is not a face, which is a failed lookup rather than a third answer.

`isLimitReached` is one name for what is currently four expressions in four files. Naming it does not merge
them; it makes the fact that they have to agree visible.

## 7. History

| Name | Values | Truth |
| --- | --- | --- |
| `lastEventNumber` | a number | `MAX(device_event.event_number)`, checked against what the cube can reach |
| `historyFrameState` | `event` / `noSuchEvent` / `endOfStream` | `DeviceHistoryRules` |
| `isSingleFrameRequest` | true / false | the request's own shape |

`historyFrameState` is three answers currently spread across two booleans, which is the shape the convention
says is an enum: today `isNoSuchEvent` has to check `!isEndOfStream` first to avoid answering about the wrong
frame.

## 8. Google and calendar sync

| Name | Values | Truth |
| --- | --- | --- |
| `googleAccountState` | `notConnected`, `signedOut`, `unverified`, `connected`, `expired`, `unreachable`, `unreadable` | `GoogleAccountRules.State` |
| `hasGoogleCredentials` | true / false | client credentials present |
| `hasGoogleIdentity` | true / false | `GoogleAccountRules.Account` |
| `isCalendarGone` | true / false | `CalendarGone` |
| `hasReportedMissingCalendar` | true / false | `CalendarSync` |
| `hasReportedWriteFailure` | true / false | `DebugLog` |
| `hasReachedCube` | true / false | `CubeNotFoundOffer` |

## 9. Settings window and list UI

View state. Listed because it appears in branches, not because anything outside the window should read it.

| Name | Values | Truth |
| --- | --- | --- |
| `settingsTabState` | `faces`, `categories`, `report`, `app`, `device` | AppKit's `selectedTabViewItem`; the cases are `SettingsTab` |
| `isExpanded` | true / false | `PanelSection` / `DisclosureRow` |
| `isEditing` | true / false | `CategoryCreateControl` |
| `isSelected` | true / false | per list |
| `isHidden` | true / false | AppKit |
| `isEnabled` | true / false | AppKit |

`isEnabled` and `isHidden` belong to `NSControl` and `NSView` and are not ours to rename. Our own answers to
"may this be pressed" (`isClickable`, `isButtonEnabled`, `isSelectable`) are **not** states and are not renamed
to `isEnabled`: they are decisions computed from state, and the last section says why that matters.

## 10. Report tab

| Name | Values | Truth |
| --- | --- | --- |
| `isInMonth` | true / false | `ReportCalendarGrid` |
| `isRangeStart` | true / false | `ReportCalendarGrid` |
| `isRangeEnd` | true / false | `ReportCalendarGrid` |
| `isSameDay` | true / false | `ReportCalendarGrid` |
| `isSameMonth` | true / false | `ReportCalendarGrid` |
| `isEmphasised` | true / false | `ReportCalendar` |
| `isSortAscending` | true / false | `ReportSortRules.Direction` |
| `sortColumnState` | `category` / `time` | `ReportSortRules.Column` |

---
## What the convention does not govern

Naming everything `is` or `State` would take in things that are not state.

- **Numbers and identifiers.** `cubeFace`, `batteryPercent`, `dailyLimitMinutes`, `lastEventNumber`. A face is
  1 to 12, not a set of named cases, and `cubeFaceState` would imply an enum that should not exist. The
  convention has no rule for these and this file does not invent one: they are named for what they hold.
- **Decisions.** `ManualTimerRules.isClickable`, `DeviceReconnectRules.shouldAttempt`,
  `StatusItemClickRouter.action`, `PauseMenuRules.target`, `FacesTabRules.doesAnything`. These answer "what
  should happen", computed from the states above. A decision is named for what it decides. Where one returns
  named outcomes it is already an enum (`StatusItemClick`, `DailyLimitAction`, `ForcedPauseAction`,
  `CubeNotFoundAnswer`, `DeviceLoginOutcome`) and does not take the `State` suffix, because an action is not a
  state.
- **Reports of what just happened.** `DeviceEventRecorder.Outcome.wasInserted` and `.isOpen` describe a write
  that has already run, not what the table now holds. `Outcome.isOpen` is therefore not renamed to
  `isSegmentOpen`.
- **A row's own columns.** `DeviceEventSegment.isPaused`, `TimeEntryRecorder.Row.isPaused` and `.isFinalised`,
  and `DeviceCommandRules.Status.isLocked` and `.isPaused` are fields of one decoded record, mirroring `paused`
  and `finalised`. **A finalised row saying it was a pause is history, not what the cube is doing now**, and the
  three-case states above exist precisely because the live question has an `unknown` that a decoded row never
  has. So these keep their boolean names, and `cubePauseState` is built from them rather than replacing them.
- **AppKit's own names.** `isEnabled`, `isHidden`, `isActive` on `NSLayoutConstraint`, `wantsLayer`,
  `needsLayout`. Not ours, and `isActive` is why `category.active` becomes `isCategoryActive` rather than
  `isActive`.
- **Database columns.** `paused`, `locked`, `finalised`, `processed`, `active`, `daily_limit`. SQL names set
  by the DDL. The Swift-side reader takes the name from this file.

---

## Where the rename list lives

What each of these is called in the code today, and the mapping from that to the name above, is the sweep
list in `docs/state-audit.md`. It belongs there because it is a record of this codebase at this moment,
while this file is the naming itself.

## Adding a state

New code uses these names. If a branch needs a fact that is not here, add it here in the same change, and pick
the name by the convention at the top: two answers means `is<Name>`, more than two means `<name>State`, and
the subject goes in the name either way.
