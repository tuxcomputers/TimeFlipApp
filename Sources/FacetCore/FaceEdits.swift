import Foundation

/// What the Faces tab does when one of its controls is used: a category clicked, the clock pressed, the face's lock
/// turned.
///
/// **The companion to `CategoryEdits`, and core for the same reason**: there are two Faces tabs now, and every
/// decision in here was made once in `SettingsWindowController` when there was only one. What is left for a
/// platform is drawing a cube, a list and a clock.
///
/// **Three gestures, and the interesting one is a click on a category**, which means three different things
/// depending on what the app is doing: put the category on the face a cube is resting on, start the app's own clock
/// on it, or nothing at all. Which of those it is is `FacesTabRules`', and it is asked here *and* when the list is
/// drawn -- the archive's own arrangement, kept because of what happened without it: with the cube resting on a
/// locked face, clicking a category produced a log row and nothing else at all, on a database built from the DDL,
/// because `008_face.sql` seeds faces 2 and 8 locked.
///
/// **Nothing here holds a reading.** Every method reads the table at the moment it acts, which matters more on this
/// tab than anywhere else in the app: the cube can be turned between a row being drawn and the click on it landing,
/// so a gesture that worked from what was drawn would write to a face nobody was looking at.
@MainActor
package final class FaceEdits {
    private let faces: FaceStore
    private let timing: TimingReadout
    private let events: DeviceEventRecorder
    private let debugLog: DebugLog?

    /// Whether this launch is timing by hand, which is the only thing that lets a click start the app's own clock
    /// while a device is on record. A closure because it is derived from the connection rather than stored: see
    /// `CLAUDE.md` on the manual mode flag that used to sit beside the connection status.
    private let isManualMode: () -> Bool

    /// Whether the category being timed has spent its budget for the day. Asked at the moment of the press, never
    /// remembered: a limit raised on the Categories tab has to be able to let the clock start again.
    private let isLimitReached: () -> Bool

    /// The cube's LEDs, where there is a cube. A face that has just taken a different category is lit in the old
    /// one's colour until it is told.
    package var faceColours: FaceColourSync?

    /// Draw the tab again from the table. What it draws is the caller's; that this is the moment to is not.
    package var changed: (@MainActor () -> Void)?

    /// The status item, the app's own clock, and anything else drawn from a reading. The Mac's `onTimingChanged`.
    package var timingChanged: (@MainActor () -> Void)?

    package init(
        faces: FaceStore,
        timing: TimingReadout,
        events: DeviceEventRecorder,
        isManualMode: @escaping () -> Bool,
        isLimitReached: @escaping () -> Bool,
        debugLog: DebugLog?
    ) {
        self.faces = faces
        self.timing = timing
        self.events = events
        self.isManualMode = isManualMode
        self.isLimitReached = isLimitReached
        self.debugLog = debugLog
    }

    /// What a click on a category row would do at this moment, which is also what decides whether the row is drawn
    /// live at all.
    ///
    /// **The same question `start` answers, exposed so the drawing can ask it.** One answer read twice, never two
    /// conditions written out separately: a row that looks live has to be one that does something.
    package func click(for reading: TimingReadout.Reading) -> FacesTabRules.Click {
        FacesTabRules.click(
            cubeFace: reading.cubeFace,
            isFaceLocked: isFaceLocked(reading.cubeFace),
            isManualMode: isManualMode(),
            isCubeConnected: reading.isCubeConnected
        )
    }

    /// Whether the face a cube is resting on keeps what it has. `false` for no face at all, which is the answer the
    /// rules want: there is nothing to be locked.
    package func isFaceLocked(_ face: Int?) -> Bool {
        face.map { faces.isFaceLocked(face: $0) == true } ?? false
    }

    // MARK: - a category was clicked

    /// A category was clicked: the segment that was running ends, the **next** manual face takes the new category,
    /// and a new segment starts on it -- or the cube's face takes it, or nothing happens.
    ///
    /// One moment is read for the whole gesture, so the segment that ends and the one that begins meet exactly
    /// rather than overlapping or leaving a gap nobody timed.
    ///
    /// **The new category goes on a different face from the one the finished segment named**, which is what makes
    /// the outgoing segment's category safe no matter when anything reads it. Closing before writing the face is
    /// still the right order and still done, but it is no longer the only thing standing between a finished stretch
    /// and being filed under the category that replaced it -- see `ManualFace`.
    package func start(_ category: CategoryRecord, at moment: Date = Date()) {
        let reading = timing.read()
        switch click(for: reading) {
        case let .assignToFace(face):
            assignToCube(face: face, category)
            return
        case let .faceIsLocked(face):
            debugLog?.record(
                .mode,
                "Face \(face) is locked, so it keeps what it has rather than taking \(category.name)"
            )
            return
        case .waitingForTheDevice:
            debugLog?.record(
                .mode,
                "Timing: \(category.name) was not started -- a device is paired, and manual mode has not been chosen"
            )
            return
        case .startTiming:
            break
        }
        // Already timing this one, so the click has nothing to ask for: the clock is where it should be, and
        // restarting it would rotate the face and close a segment for a gesture that asked for no change. Ahead of
        // the face write as well as the segment, since the face already holds this category too.
        //
        // Recorded even though nothing happened. A click that deliberately did nothing and a click that never
        // landed look identical afterwards unless one of them leaves a row, and telling those apart is the
        // difference between this working and the list having stopped responding.
        if reading.isTiming(category.id) {
            debugLog?.record(.mode, "Timing: already timing \(category.name), so the click changes nothing")
            return
        }
        // Read before anything is written, so the face the finished segment is on is not the face about to be
        // reassigned.
        let face = ManualFace.next(after: events.latestFace(in: ManualFace.all))
        events.closeOpenSegment(at: moment)
        // A refused write here leaves the outgoing segment closed with no new one open, and the clock still
        // claiming to run. That is worth naming rather than guarding: the close is right on its own terms (the
        // stretch did end when the click arrived), and the only way to reach this is the database refusing an
        // update -- the app's own faces are never locked, being reassigned is the whole point of them.
        guard faces.assign(categoryID: category.id, toFace: face) else {
            debugLog?.record(.mode, "Timing: face \(face) refused category \(category.name)")
            return
        }
        events.startSegment(face: face, at: moment)
        debugLog?.record(.mode, "Timing: started \(category.name) (category_id \(category.id)) on face \(face)")
        // The tick is not started here: what redraws reads what is now open and decides it from that, so a click
        // that started nothing cannot leave a clock running behind it.
        changed?()
        timingChanged?()
    }

    /// A category was clicked while a cube is connected: the face the cube is resting on takes it, and that is all.
    ///
    /// **The archive's `pickCategory`, and its reasoning survives**: somebody looking at a lit cube and clicking a
    /// category is saying "this face is that", and making them find the face in a list afterwards would be saying it
    /// twice.
    ///
    /// **No segment, no clock, no tick.** The cube is doing the timing, so opening a segment here would be the app
    /// recording a stretch it did not measure. The click changes which category a face names and nothing else, which
    /// is why this is a separate path rather than a flag inside `start`.
    private func assignToCube(face: Int, _ category: CategoryRecord) {
        // **The lock is not re-asked here.** `FacesTabRules` decided before this was called, from the same read the
        // list was drawn from, and asking again would be a second answer that could differ from the one the user is
        // looking at. The write refuses a locked face on its own anyway (`FaceStore.assign`), which is where that
        // guarantee belongs.
        //
        // The click asked for no change, and saying so is what tells a deliberate no-op apart from a list that has
        // stopped responding -- the same reason the manual path records its own.
        guard faces.categoryID(forFace: face) != category.id else {
            debugLog?.record(.mode, "Face \(face) already holds \(category.name), so the click changes nothing")
            return
        }
        guard faces.assign(categoryID: category.id, toFace: face) else {
            debugLog?.record(.mode, "Face \(face) refused category \(category.name)")
            return
        }
        debugLog?.record(.mode, "Face \(face) now holds \(category.name) (category_id \(category.id))")
        // The cube lights this face in its category's colour, so a face that has just taken a different category is
        // showing the wrong one until it is told. One face, not all twelve: nothing else moved.
        faceColours?.send(face: face, because: "face \(face) took \(category.name)")
        changed?()
        // **Through the same funnel, though no clock started.** What this means here is "the reading changed, and
        // the status item draws that reading too" -- nothing else tells it, since a face callback fires on a turn of
        // the cube and not on a face being given a different category.
        timingChanged?()
    }

    // MARK: - the clock

    /// Stop the clock, or start it again.
    ///
    /// **One path for both ways in**: the control in the Timing column and the dropdown's Pause item both end here,
    /// so they cannot come to disagree about what pausing means. The previous app had them as two implementations
    /// and they did exactly that.
    ///
    /// **Pausing ends the segment; resuming begins another.** A segment's duration is the wall time from its start,
    /// so a pause left sitting inside one would be counted as time spent -- and it was, until this: the clock read
    /// 14 seconds against a row claiming 20.
    ///
    /// - Returns: what the table holds afterwards, or `nil` when nothing was done -- a refused resume, or nothing
    ///   being timed at all. A caller that draws a clock uses it to decide whether to keep ticking; one that does
    ///   not can ignore it.
    @discardableResult
    package func togglePause(at moment: Date = Date()) -> TimingReadout.Reading? {
        // **The decision is `ManualClock`'s and the drawing is the caller's.** Three controls reach it, one of them
        // with no window on screen at all, so what it decides is not a window's to own.
        guard let after = ManualClock.toggle(
            timing: timing,
            events: events,
            isLimitReached: isLimitReached(),
            at: moment,
            debugLog: debugLog
        ) else { return nil }
        changed?()
        timingChanged?()
        return after
    }

    // MARK: - the lock on the cube's face

    /// Locks or unlocks the face the cube is resting on.
    ///
    /// **Which face, and whether it is locked, are both read here rather than taken from the control.** The lock
    /// draws what the table said when the tab was last drawn, and the cube can be turned between that and the click
    /// landing; a toggle working from what was drawn would then lock a face nobody was looking at.
    ///
    /// **The tab is redrawn from the table afterwards, not from what was asked for**, which is `CLAUDE.md`'s rule
    /// about reading back after a write: a refused write shows as the lock it really is rather than the one that was
    /// wanted. It also redraws the list, since the lock is exactly what decides whether the rows are live.
    package func toggleLock() {
        guard let face = timing.read().cubeFace else {
            // Not reachable through the control, which is not drawn when there is no cube -- but the closure
            // outlives any one drawing of it, and a click landing as the link drops would otherwise write to
            // whatever face was last on screen.
            debugLog?.record(.click, "The lock was pressed with no cube face to lock")
            return
        }
        let wanted = !(faces.isFaceLocked(face: face) ?? false)
        debugLog?.record(.click, "Button clicked: face \(face) lock -> \(wanted ? "locked" : "unlocked")")
        if !faces.setLocked(wanted, face: face) {
            debugLog?.record(.click, "Face \(face) would not take the lock")
        }
        changed?()
    }
}
