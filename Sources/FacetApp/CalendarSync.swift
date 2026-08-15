import Foundation

/// Gets recorded time into the user's Google calendar, and ticks `time_entry.synced_to_google_calendar` once it is
/// there and has been checked.
///
/// **A sweep of the table, not a hand-off of one row.** Recording an entry is what triggers it, but what runs is
/// "every entry that is not synced yet", oldest first. That is the difference between a feature that works and one
/// that works while the network does: an entry that failed to reach Google is not lost or queued somewhere else, it is
/// simply still `0` in the column, and the next entry recorded picks it up along with its own. `docs/operation-spec.md`
/// § 5 asked for exactly this and gave the reason -- re-delivery is cheap enough that no retry count or backoff column
/// is needed.
///
/// **Nothing is remembered between passes.** The calendar id, the entries and their categories are all read from the
/// database at the start of each pass, per the first rule in `CLAUDE.md`. A calendar disconnected while a sweep was
/// running is therefore noticed on the next pass rather than written to anyway.
///
/// There is **no prior art for this** in the archive. `Archive/TimeFlipApp/GoogleCalendarClient.swift` has an
/// `insertEvent`, and `docs/rebuild.md` records that nothing ever called it and that no code there ever wrote
/// `synced_to_google_calendar`. What that file does contribute is the event's shape, which is massaged into
/// `GoogleEventRules` rather than copied.
@MainActor
final class CalendarSync {
    private let connection: DatabaseConnection
    private let settings: SettingStore
    private let debugLog: DebugLog?
    /// Injected so the sweep can be exercised without a Keychain or a network. In the app it is
    /// `GoogleCalendarClient.currentAccessToken`, which resolves the signed-in account afresh on every call.
    private let accessToken: () async throws -> String

    init(
        connection: DatabaseConnection,
        settings: SettingStore,
        debugLog: DebugLog?,
        accessToken: @escaping () async throws -> String = { try await GoogleCalendarClient.currentAccessToken() }
    ) {
        self.connection = connection
        self.settings = settings
        self.debugLog = debugLog
        self.accessToken = accessToken
    }

    /// A pass is running.
    private var isSweeping = false
    /// Somebody asked for a sweep while one was running, so go round again when it finishes rather than dropping the
    /// request. Two flips in quick succession must not leave the second one's entry sitting until a third.
    private var wantsAnotherPass = false
    /// "Nothing is connected" is reported once per launch, not once per flip. Somebody who never signs in would
    /// otherwise get a line in the log every time they turn the cube, which buries everything else -- and the same
    /// silence would leave "why is nothing syncing?" with no answer at all. Cleared when a sweep gets going, so it
    /// says so again if the connection later goes away.
    private var hasReportedNothingToSyncInto = false

    /// Asks for a sweep. Returns immediately: the work is a task, and the caller is on the path that just recorded an
    /// entry.
    ///
    /// Safe to call as often as anything likes. A second call while a pass is running sets a flag rather than starting
    /// a second pass, so two sweeps cannot be sending the same entry at the same time.
    func sweep(because reason: String) {
        guard !isSweeping else {
            wantsAnotherPass = true
            return
        }
        isSweeping = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            var again = true
            while again {
                self.wantsAnotherPass = false
                let outcome = await self.pass(because: reason)
                // A full batch means there is more waiting, so keep going rather than leaving the rest until the next
                // flip. A failed pass stops: whatever refused the first entry will refuse the rest, and spinning on it
                // would be a request per unsynced row against a quota, achieving nothing.
                again = self.wantsAnotherPass || outcome == .moreWaiting
            }
            self.isSweeping = false
        }
    }

    /// What one pass came to.
    private enum Outcome: Equatable {
        /// Everything that was waiting is done.
        case drained
        /// A full batch went through and there are more rows behind it.
        case moreWaiting
        /// Nothing was attempted, or something refused. Either way, do not immediately go round again.
        case stopped
    }

    // MARK: - one pass

    private func pass(because reason: String) async -> Outcome {
        // Read now, every pass. Not held from the last one, and not passed in by whoever asked for the sweep.
        let pending = pendingEntries(limit: GoogleEventRules.batchSize)
        guard !pending.isEmpty else { return .drained }

        let calendar = GoogleCalendarRules.calendar(
            id: settings.string(GoogleAccountRules.setting, field: GoogleCalendarRules.idField),
            name: settings.string(GoogleAccountRules.setting, field: GoogleCalendarRules.nameField)
        )
        guard let calendarID = calendar.id else {
            reportNothingToSyncInto("no calendar is connected", waiting: pending.count)
            return .stopped
        }

        let token: String
        do {
            token = try await accessToken()
        } catch {
            reportNothingToSyncInto(error.localizedDescription, waiting: pending.count)
            return .stopped
        }

        hasReportedNothingToSyncInto = false
        debugLog?.record(.sync, "Calendar sync started (\(reason)), \(pending.count) waiting")

        var synced = 0
        var skipped = 0
        for entry in pending {
            switch await send(entry, to: calendarID, token: token) {
            case .synced:
                synced += 1
            case .skipped:
                // This row cannot be delivered, and the rows behind it have nothing to do with it. Carrying on is
                // what stops one bad entry holding up every later one -- which is exactly what happened the first
                // time this ran: `time_entry` 27 failed its check and the 39 good entries behind it never went.
                skipped += 1
            case .stopped:
                debugLog?.record(.sync, "Calendar sync stopped after \(synced) of \(pending.count)")
                return .stopped
            }
        }
        debugLog?.record(
            .sync,
            "Calendar sync finished, \(synced) event\(synced == 1 ? "" : "s") into \(calendar.name ?? "the calendar")"
                + (skipped > 0 ? ", \(skipped) left for later" : "")
        )
        // **Only go round again if something actually moved.** A full batch that synced nothing is a batch that will
        // read back the same rows and fail the same way, so looping on it would be a pair of requests per skipped row
        // for as long as the app runs.
        guard synced > 0 else { return .stopped }
        return pending.count == GoogleEventRules.batchSize ? .moreWaiting : .drained
    }

    /// What delivering one entry came to.
    ///
    /// **The distinction is whose problem it is.** A row Google will not accept says nothing about the next row, and a
    /// sweep that stopped on it would let one entry hold back every later one. A refused *request* -- an expired
    /// sign-in, a quota, a calendar that is not there -- will refuse the next one identically, so continuing would be
    /// a pointless request per remaining row.
    private enum Delivery {
        case synced
        case skipped
        case stopped
    }

    /// Creates one entry's event, checks it, and ticks the row.
    ///
    /// The three steps are deliberately not collapsed: creating and verifying are separate requests because the flag
    /// claims the event is *right*, not that a request succeeded, and the tick is last because a row marked synced is
    /// never looked at again.
    private func send(_ entry: Pending, to calendarID: String, token: String) async -> Delivery {
        let expected = expectation(for: entry)
        do {
            switch try await GoogleEventClient.insert(expected, calendarID: calendarID, accessToken: token) {
            case .created:
                break
            case .alreadyThere:
                // A previous pass wrote it and did not get as far as the tick. The read-back below is what says
                // whether that event is the one this entry wants.
                debugLog?.record(.sync, "Calendar event \(expected.eventID) was already there")
            }

            let kept = try await GoogleEventClient.get(
                eventID: expected.eventID, calendarID: calendarID, accessToken: token
            )
            if let mismatch = GoogleEventRules.mismatch(between: kept, and: expected) {
                // Left unsynced on purpose. The column means "there is a correct event for this row", and there is not
                // one, so saying otherwise would close the question for good.
                debugLog?.record(
                    .sync,
                    "Calendar event \(expected.eventID) does not match time_entry \(entry.timeEntryID): \(mismatch.described)"
                )
                return .skipped
            }
            guard markSynced(entry.timeEntryID) else {
                // The database refusing a write is not this row's problem, it is everything's.
                debugLog?.record(.sync, "time_entry \(entry.timeEntryID) has its event but the table refused the tick")
                return .stopped
            }
            return .synced
        } catch GoogleEventClient.Failure.missing {
            // Inserted a moment ago and already not there. Odd, and specific to this event rather than to the request.
            debugLog?.record(.sync, "Calendar event \(expected.eventID) was not there to read back")
            return .skipped
        } catch {
            debugLog?.record(
                .sync,
                "Calendar event for time_entry \(entry.timeEntryID) failed: \(error.localizedDescription)"
            )
            return .stopped
        }
    }

    private func expectation(for entry: Pending) -> GoogleEventRules.Expected {
        GoogleEventRules.Expected(
            eventID: GoogleEventRules.eventID(forTimeEntry: entry.timeEntryID),
            summary: entry.categoryName,
            description: GoogleEventRules.description(
                timeEntryID: entry.timeEntryID, deviceEventID: entry.deviceEventID
            ),
            startEpoch: entry.startEpoch,
            // The start plus the length, as everywhere else in this app: a recorded stretch is a beginning and a
            // duration, and `time_entry.ended_at` is local text with no offset that would have to be parsed back
            // through its zone to become a moment (see `TimeEntryStore`).
            //
            // **`Int(...)`, matching what `TimeEntryRecorder` wrote into `ended_at`** for the same row, which
            // truncates the same way. Some `duration_seconds` values carry a fraction -- they are a REAL column and
            // older rows have one -- and Google is given whole seconds, so the event ends where the table says it
            // ends rather than 0.6 of a second later.
            endEpoch: entry.startEpoch + Int(entry.durationSeconds),
            timeZoneName: GoogleEventRules.timeZone(named: entry.timezoneName).identifier
        )
    }

    private func reportNothingToSyncInto(_ reason: String, waiting: Int) {
        guard !hasReportedNothingToSyncInto else { return }
        hasReportedNothingToSyncInto = true
        debugLog?.record(.sync, "\(waiting) entr\(waiting == 1 ? "y" : "ies") waiting to sync, but \(reason)")
    }

    // MARK: - what the table says

    /// One entry, in the terms an event needs.
    private struct Pending {
        let timeEntryID: Int
        let deviceEventID: Int
        let categoryName: String
        let startEpoch: Int
        let durationSeconds: Double
        let timezoneName: String?
    }

    /// The entries with no event yet, **oldest first**, so a backlog arrives in the order the time was spent.
    ///
    /// The start comes from `device_event.start_epoch` rather than `time_entry.started_at`, as it does everywhere in
    /// this codebase: the epoch is a number, and the text column is local time carrying no offset.
    private func pendingEntries(limit: Int) -> [Pending] {
        var found: [Pending] = []
        connection.forEachRow(
            """
            SELECT te.time_entry_id, te.device_event_id, c.category_name,
                   de.start_epoch, te.duration_seconds, tz.timezone_name
              FROM time_entry te
              JOIN device_event de ON de.device_event_id = te.device_event_id
              JOIN category c ON c.category_id = te.category_id
              JOIN timezone tz ON tz.timezone_id = te.start_timezone_id
             WHERE te.synced_to_google_calendar = 0
             ORDER BY de.start_epoch, te.time_entry_id
             LIMIT \(limit);
            """
        ) { row in
            found.append(
                Pending(
                    timeEntryID: Int(row.int(0)),
                    deviceEventID: Int(row.int(1)),
                    categoryName: row.string(2) ?? "",
                    startEpoch: Int(row.int(3)),
                    durationSeconds: row.double(4),
                    timezoneName: row.string(5)
                )
            )
        }
        return found
    }

    /// Ticks the row, and **reads it back to prove it took**, which is the same rule `SettingStore.write` follows: a
    /// write that reported success and did not happen would leave the app believing an entry is done while the table
    /// keeps offering it, forever.
    private func markSynced(_ timeEntryID: Int) -> Bool {
        guard connection.execute(
            "UPDATE time_entry SET synced_to_google_calendar = 1 WHERE time_entry_id = \(timeEntryID);"
        ) else {
            return false
        }
        var ticked = false
        connection.forEachRow(
            "SELECT synced_to_google_calendar FROM time_entry WHERE time_entry_id = \(timeEntryID);"
        ) { row in
            ticked = row.bool(0)
        }
        return ticked
    }
}
