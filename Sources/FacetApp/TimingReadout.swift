import Foundation

/// What is being timed right now: which category, whether its clock is running, and how much time it has today.
///
/// **One answer, for everything that draws it.** The Faces tab and the status item show the same session, and the
/// previous app let each work it out for itself: the menu bar resolved the activity from the face and totalled the
/// day, then handed the tab the duration *text* it had already formatted
/// (`Archive/TimeFlipApp/AppState.setCurrentDurationText`), so the tab's figure was whatever the menu bar last
/// happened to say. Reading it in one place is what stops the two disagreeing about what is running, and neither
/// of them keeps a copy.
///
/// **Every field is a read taken when the answer is wanted**, per the first rule in `CLAUDE.md`. Which of the app's
/// faces is in use comes from `device_event`, the category on it from `face`, whether the clock is running from
/// whether that table holds an open segment, and the figure from `time_entry` (see `DayTotal`). Nothing is held
/// between calls, which is what makes this right after a category is renamed, after a relaunch mid-session, and
/// after somebody edits a row by hand.
///
/// **A relaunch is the case that made the running flag a read.** It used to come from an in-memory session that a
/// new launch started empty, so an app reopened after lunch drew nothing at all until something was clicked, even
/// though the table knew exactly which category had been left and how much time it had. There is no restoring step
/// here and nothing to restore: an open row means running, no open row means paused, and a launch inherits the
/// answer by asking.
@MainActor
final class TimingReadout {
    /// What a view needs in order to draw the session, and nothing else.
    struct Reading: Equatable {
        /// The category on the face being timed, or `nil` when that face holds none.
        let category: CategoryRecord?

        /// Whether the clock is running, stopped, or there is nothing to run at all.
        let state: TimingState

        /// The category's total for the day so far, in seconds. Zero when there is no category to total.
        let seconds: TimeInterval

        /// Whether that figure is going up as the clock ticks, whoever is doing the measuring.
        ///
        /// **What the two surfaces start and stop their tick on**, and it is a different question from `state`. That
        /// one is about this app's own clock, which is idle for the whole time a cube is followed; this one is about
        /// the number on screen, which moves whenever there is an open unpaused segment behind it -- the cube's as
        /// readily as the app's. Ticking on `state` was the bug: with a cube connected the menu bar and the Faces tab
        /// never started their timer at all, so a figure that was growing on every read was repainted only when a
        /// history fetch happened to redraw them, and sat up to a whole interval behind the truth in between.
        ///
        /// **Answered by `DayTotal`, which is what works the figure out**, rather than inferred here from the pause
        /// glyph. A cube that has flipped but whose history has not been fetched yet still names its new face on the
        /// reading, and the newest row for that face may be a stretch that finished an hour ago -- so "is this cube
        /// paused" and "is this total moving" are not the same answer, and only the second one is about the number.
        let isCounting: Bool

        /// The face the cube is resting on, or `nil` when there is no cube to follow and the app is timing by hand.
        ///
        /// **What tells the two pictures apart**, and it is on the reading rather than asked separately by each thing
        /// that draws so that they cannot come to disagree -- which they did: the Faces tab drew the cube's face
        /// while the menu bar went on drawing the manual session, because each asked its own question.
        let cubeFace: Int?

        /// Whether the cube itself is paused, or `nil` when there is no cube being followed -- and also when there is
        /// one that has not answered the question yet.
        ///
        /// **A different question from `state`, which is about this app's own clock.** While a cube is being followed
        /// the app is running no clock at all, so `state` is idle; what is or is not running is the cube, and this is
        /// the cube's own answer to it. Keeping them apart is what stops a cube's reading starting the status item's
        /// tick, or reading as a session that could be clicked to pause.
        let deviceIsPaused: Bool?

        /// Whether the cube this reading is about can be reached **right now**.
        ///
        /// **`cubeFace` says what to draw; this says what may be done about it.** They came apart the moment a
        /// paired cube was allowed to keep its face after the link dropped: the face, the category and the pause are
        /// the cube's own last word and are worth drawing, but nothing may be sent to a cube nobody can hear, and a
        /// click that assigned a category to it would be doing something the window cannot carry out.
        ///
        /// The archive held the same two facts in one enum -- `reconnecting` "so the menu bar keeps showing the last
        /// known activity/icon instead of tearing down", while `isCubeConnected` "gates every command that goes out over
        /// BLE" (`Archive/TimeFlipApp/AppState.swift`). Two fields here, set together in one place, so they cannot be
        /// answered differently by whoever is asking.
        ///
        /// `false` whenever there is no `cubeFace` at all, which costs nothing: there is nothing to reach.
        let isCubeConnected: Bool

        /// Written out rather than left to the memberwise one so `cubeFace` can default to "no cube": a reading is
        /// about what the app is timing unless it says otherwise, which is what every reading was before there was a
        /// cube to follow.
        init(
            category: CategoryRecord?,
            state: TimingState,
            seconds: TimeInterval,
            isCounting: Bool = false,
            cubeFace: Int? = nil,
            deviceIsPaused: Bool? = nil,
            isCubeConnected: Bool = true
        ) {
            self.category = category
            self.state = state
            self.seconds = seconds
            // Defaulted to a standing figure rather than a moving one: a reading built without saying is one nothing
            // is being measured for, and a tick started on a number that never changes is a wake-up a second for no
            // repaint at all.
            self.isCounting = isCounting
            self.cubeFace = cubeFace
            self.deviceIsPaused = deviceIsPaused
            // A reading with no face has nothing to reach, whatever the caller passed.
            self.isCubeConnected = cubeFace != nil && isCubeConnected
        }

        /// Nothing being timed, which is what a view built without a database draws.
        static let idle = Reading(category: nil, state: .idle, seconds: 0)

        /// Whether the clock is running on this category right now, which is the one case where picking it again
        /// means nothing: the clock is already where it should be, and starting it over would rotate the face and
        /// close a segment for a click that asked for no change.
        func isTiming(_ categoryID: Int) -> Bool {
            state == .running && category?.id == categoryID
        }
    }

    private let categories: CategoryStore
    private let faces: FaceStore
    private let events: DeviceEventRecorder
    private let dayTotal: DayTotal

    /// Which face the cube is resting on, asked at the moment a reading is taken. `nil` when no cube is connected,
    /// which is what makes the app fall back to what it is timing by hand.
    ///
    /// A closure rather than a radio, for the reason every dependency here is one: this is read per draw, and what it
    /// asks must be the live answer rather than one taken when the app started.
    var cubeFace: () -> Int? = { nil }

    /// Whether this launch is timing by hand, which is the one thing that stops the cube being asked about at all.
    ///
    /// **Somebody offered manual mode and taking it has said to get on without the device.** So the radio is not
    /// consulted for the rest of the launch: a cube drifting into range would otherwise appear in the menu bar and on
    /// the Faces tab an hour later, and take the click with it, since a click follows the reading. That is the app
    /// changing its mind on somebody's behalf.
    ///
    /// **The same answer the reconnect loop stands down on**, asked of `LaunchMode` per reading rather than copied
    /// here, so the two halves cannot come to disagree about whether this launch follows a cube.
    ///
    /// **The way back out is a restart, and only a restart.** Forgetting the device used to be a second way, and
    /// pairing one used to end the mode without being asked; neither does now. The mode is decided once from `paired`
    /// and is what this launch is until it closes -- see `LaunchMode`, which is the whole of why this closure's answer
    /// no longer moves under the things that read it.
    var isManualMode: () -> Bool = { false }

    /// Whether a cube is this app's cube, read from `paired` at the moment a reading is taken.
    ///
    /// **What tells a cube that has gone quiet from no cube at all**, which are two situations the app had no way to
    /// tell apart. A link drops -- out of range, asleep, batteries out -- and `cubeFace` goes with it, because a
    /// face left behind is a claim about hardware nobody can hear. Without this the reading then fell through to the
    /// app's own faces and built a manual session out of them: the menu bar drew a category on face 13 that nobody
    /// had picked, ticking, while the Device tab said the cube was unreachable and the launch was not a manual one
    /// throughout. Two pictures of one question, which is the fault the first rule in `CLAUDE.md` is about.
    ///
    /// The archive kept these apart with a `reconnecting` case, "distinct from `.failed`/`.disconnected` so the menu
    /// bar keeps showing the last known activity/icon instead of tearing down to an unpaired look"
    /// (`Archive/TimeFlipApp/AppState.swift`). This is that case, asked rather than stored.
    var isCubePaired: () -> Bool = { false }

    /// What the cube itself last said about being paused, from its answer to `0x10`. `nil` when it has not been asked
    /// or there is no link to ask over.
    ///
    /// **Only ever a fallback, and only before there is history.** `device_event`'s `paused` is the answer wherever
    /// there is a row for the face, because it is the cube's own record of an interval rather than a snapshot. But a
    /// launch asks the cube how it is (`Asking the cube what state it is in`) before the first history fetch has
    /// landed, and until then there is no row to read -- so the glyph would be missing for exactly the seconds
    /// somebody is watching the app start. This fills that gap and then stops mattering: the moment a frame arrives
    /// the row wins, and it goes on winning.
    ///
    /// **A locked cube reports itself paused whatever its pause byte says** (`DeviceCommandRules.Status`), so this is
    /// only as true as the question that produced it. That is another reason it yields to the history the moment
    /// there is any.
    var cubeSaysPaused: () -> Bool? = { nil }


    init(categories: CategoryStore, faces: FaceStore, events: DeviceEventRecorder, dayTotal: DayTotal) {
        self.categories = categories
        self.faces = faces
        self.events = events
        self.dayTotal = dayTotal
    }

    /// The session as it stands at `now`.
    func read(at now: Date = Date()) -> Reading {
        // **A cube wins whenever there is one** -- unless this launch has been told to get on without one. What the
        // app is timing by hand is otherwise a stand-in for exactly the device that has turned up, so a reading taken
        // while a cube is connected is about the cube. Both questions are asked here rather than resolved by whoever
        // set the closures, so there is one place that decides which of the two pictures a reading describes.
        if !isManualMode(), let cubeFace = cubeFace() {
            // Read here rather than held, like the manual face's: a category renamed, recoloured or reassigned
            // between two flips draws differently on the second one with nothing having to be told.
            let category = faces.categoryID(forFace: cubeFace).flatMap { categories.category(id: $0) }
            return Reading(
                category: category,
                // **Idle, and not because nothing is happening.** The cube is timing -- it always is -- but this app
                // is running no clock of its own while it follows one, so there is no session here to call running or
                // to offer anybody a pause on. Whether the *figure* is moving is `isCounting` just below, and they are
                // deliberately two answers: one is about this app's clock, the other about the number on screen.
                state: .idle,
                // **The category's total for the day, the same figure a manual session shows and read the same way.**
                //
                // The recorded part is `time_entry`, filled in by the cube's own history as each stretch finishes, and
                // the part still running is worked out from the open row's `start_epoch` and this machine's clock --
                // so it moves second by second rather than in the steps a history fetch would leave.
                //
                // **Which is the whole of what "the internal clock draws it" means.** The cube's own measurement of
                // the stretch lands in `duration_seconds` on the next fetch and is what the day is finally totalled
                // from; between fetches this machine counts, because it is the only thing here counting at all. The
                // archive did the same, differently held: it kept an `activityStartDate` and re-anchored it to
                // `Date() - elapsed` on every frame (`MenuBarController.applyElapsed`). The anchor here is the row's
                // own start, so there is nothing to keep in step and nothing to re-anchor.
                seconds: category.map { dayTotal.seconds(categoryID: $0.id, at: now) } ?? 0,
                // **And it moves**, which is the other half of that figure and comes from the same place. The cube is
                // timing, so the app's own clock is what carries the number between one history fetch and the next --
                // see `DayTotal.isCounting`, and `refreshOpenSegment` for why the *row* is left alone meanwhile.
                isCounting: category.map { dayTotal.isCounting(categoryID: $0.id) } ?? false,
                cubeFace: cubeFace,
                // **Out of the cube's own history, not out of a status read.** Every history frame carries the pause
                // in its face byte -- the vendor adds a paused interval "for the facet with Side + 128" -- so the open
                // segment the cube reported *is* whether it is paused, refreshed on every fetch and needing nothing
                // asked for on its own. It was `0x10` and a per-flip re-ask before ingestion existed, which was the
                // best available then and is strictly worse now: that answer went stale the moment somebody
                // double-tapped, and this one arrives with the record of the double tap itself.
                //
                // **The `paused` column for this face, whichever row it is in.** Asked by face rather than by which
                // row happens to be open: a manual segment carries the epoch as its event number and is very often
                // the newest open row, so `openSegment()` answers about the app's clock instead and the glyph
                // disappeared under a connected cube whenever both had been used.
                // **The row first, the cube's own answer only until there is one.** See `cubeSaysPaused`: a launch
                // has asked `0x10` before the first history fetch lands, and without the fallback the glyph is
                // missing for exactly the seconds somebody is watching the app start.
                deviceIsPaused: events.latestSegment(in: [cubeFace])?.isPaused ?? cubeSaysPaused()
            )
        }
        // **A cube that has gone quiet is not the app timing by hand.** Reached when a cube is on record and this
        // launch has not been told to get on without it, but there is no live face to read: the link has dropped and
        // is being reached for again (`DeviceReconnector.noteDropped`). What it keeps showing is the cube's own last
        // segment, out of `device_event`, which is still a true account of what the cube was doing -- it has simply
        // stopped being confirmable. Falling through instead would draw a session on one of the app's own faces,
        // which is a picture of something nobody started.
        //
        // **Nothing here claims the reading is live.** `cubeFace` names the cube's face, so a click still lands on
        // it and is refused rather than starting the app's clock (`FacesTabRules.click`), which is the same answer a
        // connected cube gives and the right one: this app does not time on a cube's face.
        if !isManualMode(), isCubePaired() {
            // **The cube's own faces, asked for by face rather than by whichever row is open.** A manual segment
            // carries the epoch as its event number, so it always looks like the newest thing in the table and the
            // open row is very often the app's rather than the cube's -- the same trap `newestFromTheCube` exists
            // for. Asking which of faces 1 to 12 was written to last cannot be answered by a manual row at all.
            guard let lastSeen = events.latestSegment(in: Array(1...ManualFace.highestDeviceFace)) else {
                // A cube on record that has never reported a face, so there is nothing of its to show. The app's own
                // faces are not its stand-in: the item falls back to the app's name rather than to a session.
                return Reading(category: nil, state: .idle, seconds: 0, cubeFace: nil)
            }
            let category = faces.categoryID(forFace: lastSeen.face).flatMap { categories.category(id: $0) }
            return Reading(
                category: category,
                state: .idle,
                seconds: category.map { dayTotal.seconds(categoryID: $0.id, at: now) } ?? 0,
                // **Still moving, and it should be.** The cube goes on timing whether this app can hear it or not, and
                // the figure here is worked out from the open row and this machine's clock rather than from anything
                // the link would have carried -- so freezing it while the cube is out of range would be showing a
                // number that the very next read disagrees with. The archive kept its clock running through a
                // reconnect for the same reason (`AppState`'s `reconnecting`, "keeps showing the last known
                // activity/icon instead of tearing down").
                isCounting: category.map { dayTotal.isCounting(categoryID: $0.id) } ?? false,
                cubeFace: lastSeen.face,
                // **The same column the connected branch draws from, and it does not stop being the answer because
                // the link went.** `paused` is the cube's own account of what it was doing, out of its own history,
                // so the glyph goes on saying what the cube last said rather than disappearing -- which is what the
                // archive meant by keeping "the last known activity/icon" instead of tearing down.
                deviceIsPaused: lastSeen.isPaused,
                // **Drawn, but not reachable.** This is the whole of the difference between showing the cube's last
                // word and pretending the cube is there: the Faces tab draws the face and refuses a click on it.
                isCubeConnected: false
            )
        }
        let face = events.currentManualFace()
        let category = faces.categoryID(forFace: face).flatMap { categories.category(id: $0) }
        return Reading(
            category: category,
            // The face says whether there is anything to name and the open row says whether it is moving. A face
            // holding no category is idle whatever the table says about segments: there would be nothing to draw
            // beside the clock.
            state: ManualTimerRules.state(categoryID: category?.id, isRunning: isRunning(on: face)),
            seconds: category.map { dayTotal.seconds(categoryID: $0.id, at: now) } ?? 0,
            // The same question as `state == .running` here, and asked of the same open row -- but asked of the
            // figure, so that whoever draws it has one thing to tick on whichever picture the reading turns out to be.
            isCounting: category.map { dayTotal.isCounting(categoryID: $0.id) } ?? false,
            cubeFace: nil
        )
    }

    /// Whether time is being recorded on `face` at this moment, which is a question `device_event` answers on its
    /// own: **an open segment is what running means.**
    ///
    /// Nothing else is consulted, and there is no flag beside it. That is the manual-mode scar in `CLAUDE.md`
    /// applied to the clock: two answers to one question cannot fail, they can only disagree, and pausing already
    /// closes the segment -- so a second flag saying "paused" would be restating what the absence of a row says.
    ///
    /// The face is checked as well as the row's existence. A segment open on some other face is not this face's
    /// session, which is what keeps a cube's own timing (faces 1 to 12) from reading as the app's.
    private func isRunning(on face: Int) -> Bool {
        guard let open = events.openSegment() else { return false }
        return open.face == face && !open.isPaused
    }
}
