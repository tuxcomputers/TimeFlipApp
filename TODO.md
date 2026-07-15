# TODO — Code Review Findings (2026-07-14)

## Checklist

### High priority
- [x] 1. Clean up all pending BLE continuations and device state on disconnect (prevents permanent command-pipeline hang)
- [x] 2. Skip `isPaused` records in `seedFromLogbook` (pause bug still present in restart/day-reset path)
- [x] 3. Surface SQLite write failures from `AppDataStore.append` and only advance the device cursor on committed rows; add `UNIQUE(event_number)` to `logbook`
- [x] 4. Make `appendSheetRow` throw on invalid sheet URL (instead of silently advancing the cursor); quote sheet tab titles in A1 ranges
- [x] 5. Fix stale `eventTask` defer clobbering a newer task (identity check + `Task.isCancelled` after awaits)

### Medium priority
- [ ] 6. Throw immediately in `waitForBluetoothPower` when Bluetooth is already off/unauthorized
- [ ] 7. Retry (or fail pairing) when the device disconnects before the first facet event — UI currently stuck on "Connecting…"
- [ ] 8. Cancel scan/discovery timeout tasks when their continuation resumes (they can kill a later attempt)
- [ ] 9. Re-run Google flush when a trigger arrives mid-flush; add a periodic retry timer for backoff recovery
- [ ] 10. Keep one long-lived `GoogleAuthService`/`OIDAuthState` instead of unarchiving per token request
- [ ] 11. Detect 401/`invalid_grant` and flip `isAuthenticated` so revoked access surfaces in the UI
- [ ] 12. Seed the delivery cursor for a new calendar ID / sheet URL at current max rowid (avoid re-delivering the whole logbook)
- [ ] 13. Use the emitted payload (not the property) in the `$facetMappings` / `$dailyFacetDurations` / `$dailyWindowStart` sinks
- [ ] 14. Set `autoenablesItems = false` (or implement `validateMenuItem`) so the Pause menu item disables when unpaired
- [ ] 15. Debounce the client-secret Keychain write; consider dropping the mandatory client secret (PKCE desktop flow doesn't need one)
- [ ] 16. Log preferences decode failures and don't overwrite the stored blob with defaults on a failed load
- [ ] 17. Revisit destructive schema "migration" (drops all tables, including integration cursors, on any column mismatch)
- [ ] 18. Inject in-memory preferences/Keychain stubs in tests; replace the 300 ms sleep in `GoogleIntegrationCoordinatorTests` with an awaitable flush
- [ ] 19. Mock HTTP server: bind loopback-only via `requiredLocalEndpoint`; fix `handlers` retain cycle; replace semaphore hops with async/await

### Cleanup / quick wins
- [x] 20. Delete `BLEManager.swift` + `BLEManagerTests.swift` (unused; real logic is in `TimeFlipBLEDevice`)
- [x] 21. Delete or implement `MenuBarController.seedTimer` (doc claims launch-restore that doesn't exist); remove `segmentElapsedNow()` and the unreachable paused branch of `clampedCurrentSegmentElapsed`
- [x] 22. Remove dead code in `GoogleIntegrationCoordinator`: `queuePumpTask`, `record()` shim, ignored `limit` param, `DeliveryMode`, `isCalendar`
- [x] 23. Delete or implement `TimeFlipDoubleTapParameters.clamped()`; remove unused `fetchLastHistoryEventNumber()`
- [x] 24. Remove the unused `dev.evernoob.timeflip` URL scheme from `Bundler.toml`
- [x] 25. Use `TextField` (not `SecureField`) for the Google Client ID
- [x] 26. Split `SettingsViews.swift` (exceeds SwiftLint file-length limit) — extract `ReportSettingsView` first
- [x] 27. Encode and decode facet colors in the same color space (currently `.deviceRGB` → `.sRGB` drift)
- [x] 28. Index history parser reads relative to `data.startIndex` (breaks on `Data` slices)
- [ ] 29. Add `TimeFlipBLEDevice` tests via the `CentralManaging`/`PeripheralManaging` seams (disconnect-during-command, scan-timeout race) — *mock fixes done (monotonic event numbers, receive-limit comment, help text); the fake-peripheral tests are deferred until items 1 and 8 are fixed, since they exercise those exact bugs and would hang/fail today*

---

## Details

### High priority

**1. Pending BLE continuations are never cleaned up on disconnect → permanent hang.**
`Sources/TimeFlipApp/TimeFlipBLEDevice.swift:905-914` only resumes the `connection` continuation on disconnect; pending `reads`, `writes`, `notification`, `services`, and `characteristics` continuations are abandoned. If the device drops mid-command, the awaiting task never resumes and `commandGate`/`historyGate` stays locked forever. Since `ApplicationDelegate.swift:61` reuses the same device instance across reconnects, every command after reconnect queues behind the dead gate until app restart. Fix: on disconnect and in `stop()`, fail-and-clear all continuation slots, and reset `isLoggedIn`/`characteristics`/`peripheral`. Relatedly, stale `CBCharacteristic` objects from the old peripheral survive reconnection (`TimeFlipBLEDevice.swift:122-136`) and can hang reads/writes on the new peripheral the same way.

**2. The paused-elapsed-time bug (fixed in fe7f0a8) still exists in the restart/day-reset path.**
`seedFromLogbook` (`Sources/TimeFlipApp/DailyFacetTotals.swift:52-58`) sums every logbook record without checking `record.isPaused` — but paused records *are* written to the logbook. Work 2h, pause overnight, relaunch (or let the 3 a.m. reset fire), and the pause span is added back into daily totals. One `guard !record.isPaused` closes it.

**3. Silent SQLite write failure + unconditional cursor advance = permanent event loss.**
`AppDataStore.append` (`Sources/TimeFlipApp/AppDataStore.swift:68-90`) discards the results of `sqlite3_prepare_v2`/`sqlite3_step`, then `HistoryIngestor.refreshHistory` (`Sources/TimeFlipApp/HistoryIngestor.swift:74-81`) advances the device cursor regardless. A disk-full or `SQLITE_BUSY` error means those events are never stored and never re-fetched. `append` should report success, and the cursor should only advance for committed rows. Also: `INSERT OR REPLACE` is a no-op because `logbook` has no UNIQUE constraint on `event_number` — a crash between append and cursor-persist duplicates rows on relaunch, double-counting daily totals.

**4. Invalid sheet URL silently marks events as delivered.**
`appendSheetRow` logs and returns instead of throwing when the URL doesn't parse (`Sources/TimeFlipApp/GoogleIntegrationCoordinator.swift:84-88`), and `deliver()` then advances the delivery cursor — events are permanently "sent" to a sheet that received nothing. It should throw so the normal backoff path applies. Similarly, sheet tab names with spaces produce invalid A1 ranges at `GoogleIntegrationCoordinator.swift:109` — A1 notation requires quoting (`'My Sheet'!A:C`, embedded `'` doubled); rename the tab to "Time Log" and every append 400s forever.

**5. Stale event-loop task can clobber its replacement.**
The device event task's `defer { self.eventTask = nil }` (`Sources/TimeFlipApp/ApplicationDelegate.swift:189-237`) can nil out a *newer* task's handle after a disconnect/retry cycle, eventually allowing two concurrent event loops and duplicate history refreshes. Use `if self.eventTask === task { self.eventTask = nil }` and check `Task.isCancelled` after awaits.

### Medium priority

**6. Bluetooth already off at connect time hangs pairing forever.**
`waitForBluetoothPower` (`Sources/TimeFlipApp/TimeFlipBLEDevice.swift:308-317`) waits for a state *change* that never comes for terminal states. Throw immediately on `.poweredOff`/`.unauthorized`; only wait on `.unknown`/`.resetting`.

**7. Disconnect during initial pairing leaves the UI stuck on "Connecting…".**
`handleDeviceDisconnect()` (`Sources/TimeFlipApp/ApplicationDelegate.swift:243-257`) only retries when `appState.isPaired == true`, which is only set after the first facet event. A drop between `connect()` and that first event schedules no retry and never calls `pairingFailed` — retry when `appState.wantsPairing`, or surface the failure.

**8. Uncancelled scan/discovery timeout tasks can fail a later attempt.**
The 12 s timeout tasks (`Sources/TimeFlipApp/TimeFlipBLEDevice.swift:345-354, 395-403`) check only that *a* continuation exists, not whose it is — attempt A's timer can kill attempt B's connection early. Store and cancel the timeout task when the continuation resumes, or generation-tag attempts.

**9. Undelivered Google events can sit for hours.**
The flush is only triggered by a new device event, and triggers arriving mid-flush are dropped (`Sources/TimeFlipApp/GoogleIntegrationCoordinator.swift:152-157`); backoff records a timestamp but nothing schedules a retry. Set a `needsRerun` flag instead of dropping, and add a periodic retry timer.

**10. A fresh `OIDAuthState` is unarchived per token request.**
`GoogleAuthManager.accessToken()` (`Sources/TimeFlipApp/GoogleAuthManager.swift:67-70`) creates a throwaway `GoogleAuthService` each call, defeating AppAuth's refresh coalescing (concurrent refreshes race, last keychain write wins) and making the state-change observer dead code (`GoogleAuthService.swift:155-162` — its only owner deallocates immediately). Keep one long-lived service/state. Also cancel the loopback HTTP listener in the completion path (`GoogleAuthService.swift:26-66, 164-167`).

**11. 401/revocation is never detected.**
`Sources/TimeFlipApp/GoogleCalendarClient.swift:89-101` treats 401 like any other status and `accessToken()` failures don't update `isAuthenticated`. Revoke access in Google and deliveries fail forever under backoff while Settings shows "connected". Detect 401 / `invalid_grant` and flip `isAuthenticated`.

**12. Changing the calendar ID or sheet URL re-delivers the entire logbook.**
The cursor is keyed by target identifier (`Sources/TimeFlipApp/GoogleIntegrationCoordinator.swift:174-180`); a new identifier gets a nil cursor and loads everything — potentially thousands of duplicate events/rows. Seed new identifiers at current max rowid (or confirm with the user). Related: `tokenProvider()` is called once before an unbounded batch loop (lines 178-214) — a large backlog can outlive the ~1h token; refresh per batch or handle 401 mid-loop. Also invalidate `sheetTitleCache` on append failure (lines 107-128), and handle `nextPageToken` in `listCalendars` (`GoogleCalendarClient.swift:29-41`).

**13. Menu bar can render stale state.**
`@Published` emits on `willSet`, and three sinks in `Sources/TimeFlipApp/MenuBarController.swift:100-124` re-read the property (old value) instead of using the emitted payload. The `$isPaired`/`$pairingStatus` sinks already do this correctly — apply the same pattern to `$facetMappings`, `$dailyFacetDurations`, `$dailyWindowStart`.

**14. "Pause" menu item is always enabled.**
`pauseItem.isEnabled = isPaired` (`Sources/TimeFlipApp/MenuBarController.swift:157`) has no effect because the menu auto-enables items. Set `newMenu.autoenablesItems = false` or implement `validateMenuItem(_:)`.

**15. Client-secret Keychain write on every keystroke (and once at launch).**
The `$googleClientSecret` sink (`Sources/TimeFlipApp/AppState.swift:244-249`) writes to the Keychain per keystroke, and `@Published` replay writes back the just-loaded secret at startup. Debounce like other preferences / persist on commit. Also: `ApplicationDelegate.swift:21-24` mandates a client secret, but a Desktop-app OAuth client with PKCE doesn't need one — consider making it optional.

**16. A failed preferences decode silently resets everything.**
`try?` in `Sources/TimeFlipApp/PreferencesStore.swift:51-68` returns nil on a corrupt/newer payload; AppState falls back to defaults and the debounced persist overwrites the stored blob — pairing info, facet mappings, and device password gone with no log line. Log the error and avoid persisting until a real change occurs. (Same pattern: a keyed-unarchiver failure in `GoogleOAuthKeychainStore.swift:41-50` silently wipes stored auth.)

**17. Destructive schema "migration".**
Any column mismatch drops all tables (`Sources/TimeFlipApp/AppDataStore.swift:369-411`), discarding the logbook *and* integration cursors — so after re-fetching device history, previously exported events re-deliver to Google. Acceptable for a prototype, but must change before any future schema change ships.

**18. Tests touch real preferences and Keychain; timing-based sync.**
`HistoryIngestorTests` instantiate `AppState()` with the real `UserDefaults(.standard)`/Keychain stores — inject in-memory stubs. `GoogleIntegrationCoordinatorTests:66-67` sleeps 300 ms to synchronize with a detached Task — expose an awaitable flush. Failure/cursor/backoff paths (items 4, 9, 12) have no coverage.

**19. Mock HTTP server hardening.**
`NWListener` binds all interfaces with only an application-layer loopback check (`Sources/TimeFlipApp/MockEventHTTPServer.swift:63, 362-375`; the bad-encoding path at 92-95 responds before the check). Mitigated by `enableMockEvents = false`, but set `parameters.requiredLocalEndpoint` for loopback-only binding. Also: the `handlers` closure table retains `self` (leak after `stop()`, lines 28-44), and `snapshotSync`/`lastEventNumberSync` (204-224) block the network queue on a semaphore with an unsynchronized `MutableBox` write on timeout — use async/await with `MainActor.run` instead.

### Cleanup / quick wins

**20.** `Sources/TimeFlipApp/BLEManager.swift` + `BLEManagerTests.swift` are unused (and would scan forever without connecting); all real logic is in `TimeFlipBLEDevice`. Delete.

**21.** `MenuBarController.seedTimer` (`Sources/TimeFlipApp/MenuBarController.swift:51-61`) has no callers, yet its doc comment claims sessions restore on launch — either implement launch-restore or delete. Also remove `segmentElapsedNow()` (263-268) and the unreachable paused branch of `clampedCurrentSegmentElapsed` (leftovers from the pause fix), and the write-only `menu` property.

**22.** Dead code in `GoogleIntegrationCoordinator.swift`: `queuePumpTask` (line 19), `record()` no-op shim (57-61), ignored `limit` parameter of `flushPendingSessions` (63), unused `DeliveryMode` (339-342) and `isCalendar` (323-326).

**23.** `TimeFlipDoubleTapParameters.clamped()` (`Sources/TimeFlipApp/TimeFlipDoubleTapParameters.swift:14-21`) returns an identical copy — implement real bounds or delete. `fetchLastHistoryEventNumber()` (`TimeFlipBLEDevice.swift:473-484`) is never called.

**24.** `Bundler.toml:13-15` registers the `dev.evernoob.timeflip` URL scheme, but `application(_:open:)` explicitly ignores URLs. Remove the `CFBundleURLTypes` block.

**25.** The Google Client ID is entered via `SecureField` (`Sources/TimeFlipApp/SettingsViews.swift:184-196`) — it's not a secret and masking prevents paste verification. Use `TextField`; keep `SecureField` for the secret only.

**26.** `SettingsViews.swift` (629 lines) exceeds the repo's own SwiftLint `file_length` warning (600). Extract `ReportSettingsView` (lines 120-399) first; `IconGridPicker`/`FacetMappingList` can follow. Related small fixes: clear `sheetSyncError` in `cancelEditingSheetURL()` (298-306); don't surface `CancellationError` as a red error in `loadCalendars()` (385-398); disable device-setting controls with `.disabled(!appState.isPaired)` instead of silently discarding input (`TimeFlipSettingsView.swift:291-329`); stop double-writing app state in the apply helpers (view writes it, then the delegate handler writes it again).

**27.** Facet colors encode from `.deviceRGB` components but decode as `.sRGB` (`Sources/TimeFlipApp/PreferencesStore.swift:71-82`) — each save/load round trip can drift the color. Use one color space for both directions.

**28.** The history parser indexes `Data` absolutely (`Sources/TimeFlipApp/TimeFlipHistoryParser.swift:7-19`, also `TimeFlipBLEDevice.swift:457-465`) — a `Data` slice with nonzero `startIndex` would misread or crash. Index relative to `data.startIndex`. Also consider replacing the `durationTolerant` min-of-four-endian-interpretations heuristic (63-72) with a firmware-revision-based decode, or log when interpretations disagree.

**29.** Zero tests exist for `TimeFlipBLEDevice` despite the `CentralManaging`/`PeripheralManaging` protocols existing to enable them. Highest value: a fake peripheral exercising disconnect-during-command (item 1) and the scan-timeout race (item 8). Minor mock fixes while there: monotonic event numbers instead of Unix-timestamp-based (`MockTimeFlipDevice.swift:124`, collides within one second), and document the single-`receive` 2048-byte request limit in `MockEventHTTPServer`.

### Suggested order

1. Item 1 (BLE cleanup on disconnect) — the only "restart the app" class of bug.
2. Items 2–3 (paused seed + append/cursor/UNIQUE) — small changes, protect the tracked data.
3. Item 4 (sheet URL throw + title quoting) — protects the Google export path.
4. Items 20–24 (dead-code sweep) — zero risk, big readability payoff.
