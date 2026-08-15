import Foundation

/// How much time a category has today: what is recorded for it inside the day window, plus the segment still
/// running on it.
///
/// **Per category, not per face**, which is the question worth asking of these numbers. Two faces assigned the
/// same category share one budget, so their time has to add up: the previous app learned this from a
/// `daily_limit` that a 40-minute stretch on one face and 40 on another never reached. Manual mode's rotation
/// makes it true of a single session too -- consecutive stretches of one category land on different faces by
/// design, so a per-face figure would show only the latest of them.
///
/// **Every part of it is a read, taken at the moment the answer is wanted.** The window comes from
/// `daily_reset_time`, the recorded part from `time_entry`, the live part from the open `device_event` row.
/// Nothing here is kept between calls, which is what makes it correct after a relaunch, after a category is
/// renamed, and after somebody edits a row by hand.
@MainActor
final class DayTotal {
    private let settings: SettingStore
    private let entries: TimeEntryStore
    private let events: DeviceEventRecorder
    private let faces: FaceStore

    init(settings: SettingStore, entries: TimeEntryStore, events: DeviceEventRecorder, faces: FaceStore) {
        self.settings = settings
        self.entries = entries
        self.events = events
        self.faces = faces
    }

    /// Seconds this category has accumulated in the day `now` falls in.
    ///
    /// The running segment is added on top of the recorded rows rather than being one of them, because it has no
    /// `time_entry` yet -- which is exactly what stops it being counted twice. When it closes it becomes an
    /// entry, and the same figure then comes entirely from the recorded side.
    ///
    /// So a pause needs no special case at all. Pausing closes the segment, so there is no live part left to
    /// add and the number simply stops moving, without anything here knowing what a pause is.
    func seconds(categoryID: Int, at now: Date = Date()) -> TimeInterval {
        let windowStart = windowStart(at: now)
        var total = entries.seconds(categoryID: categoryID, from: windowStart, to: now)

        if let open = events.openSegment(), !open.isPaused, category(of: open) == categoryID {
            total += DayWindow.elapsedInside(
                startEpoch: Double(open.startEpoch),
                windowStart: windowStart,
                now: now
            )
        }
        return total
    }

    /// The start of the day `now` falls in, from the setting as it reads at this moment. Change the reset time
    /// and the next answer is against the new window, with nothing needing to be told.
    func windowStart(at now: Date) -> Date {
        let reset = DayWindow.resetTime(
            hour: settings.integer(Self.resetSetting, field: "hour"),
            minute: settings.integer(Self.resetSetting, field: "minute")
        )
        return DayWindow.start(at: now, resetHour: reset.hour, resetMinute: reset.minute)
    }

    /// Which category an open segment counts towards: whatever its face holds. `0` for a face with nothing on
    /// it, the seeded *Unassigned* row, which pools time from every unassigned face exactly as any other
    /// category pools its own.
    private func category(of open: DeviceEventRecorder.OpenSegment) -> Int {
        faces.categoryID(forFace: open.face) ?? 0
    }

    private static let resetSetting = "daily_reset_time"
}
