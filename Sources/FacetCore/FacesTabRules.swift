import Foundation

/// What a click on a category row does, and therefore whether the row is live at all.
///
/// **One answer, read twice, which is the archive's arrangement and the reason it exists.** There, `canAssignToFaceOnShow`
/// was read by the assignment list to decide whether its rows were live *and* by `pickCategory` to decide what a click
/// meant, with a comment saying exactly why: so the two cannot disagree. This app had the second half only, and the
/// result was watched on hardware -- with the cube resting on a locked face, clicking a category produced a log row and
/// nothing else at all. No greying, no message, no movement. On a database built from the DDL that is what happens on
/// both of the only two faces that carry a name, because `008_face.sql` seeds faces 2 and 8 locked.
///
/// So the rule is a value here rather than a condition written out at each of the two call sites, and the drawing asks
/// the same question the click answers.
enum FacesTabRules {
    /// What clicking a category row would do at this moment.
    enum Click: Equatable {
        /// Put the category on the face the cube is resting on. No clock starts: the cube is doing the timing.
        case assignToFace(Int)
        /// Start the app's own clock on it, rotating the manual faces. What every click did before there was a cube.
        case startTiming
        /// Nothing. The face keeps what it has until somebody unlocks it, which is what the lock is for.
        case faceIsLocked(Int)
        /// Nothing. There is a device on record and no reading off it, so the app is neither following a cube nor
        /// timing by hand -- it is looking. Timing by hand needs the device forgotten, which is a decision only
        /// somebody at the keyboard makes.
        case waitingForTheDevice

        /// Whether the click would do anything, which is what decides if the row is drawn live.
        ///
        /// **A dead row is the honest drawing of both refusals.** Neither of them is a failure or an error worth an
        /// alert -- one is a face somebody deliberately pinned, the other is an app that has not found its cube yet --
        /// and both are states somebody can see the reason for elsewhere on the tab: the lock is red, and the Device
        /// tab says the cube is not connected.
        var doesAnything: Bool {
            switch self {
            case .assignToFace, .startTiming: return true
            case .faceIsLocked, .waitingForTheDevice: return false
            }
        }
    }

    /// - Parameters:
    ///   - cubeFace: the face the cube is resting on, or `nil` when there is no cube being followed. This is
    ///     `TimingReadout.Reading.cubeFace`, so it is already `nil` when the app is timing by hand.
    ///   - isFaceLocked: whether that face keeps what it has. Ignored when there is no face.
    ///   - isManualMode: whether this launch is timing by hand, which is the only thing that lets a click start the
    ///     app's own clock while a device is on record.
    static func click(
        cubeFace: Int?,
        isFaceLocked: Bool,
        isManualMode: Bool,
        isCubeConnected: Bool = true
    ) -> Click {
        // **The cube first, because it is what is on screen.** A reading that names a face is what both surfaces are
        // drawing, so a click has somewhere to land whatever the mode says -- and landing it anywhere else would be a
        // control doing something other than what the window shows.
        //
        // **Unless the cube cannot be reached**, which is a face still being drawn from the cube's own last word
        // after the link dropped (`TimingReadout.Reading.isCubeConnected`). The face is worth showing and the
        // assignment is not something the app can carry out, so this answers `waitingForTheDevice` exactly as it did
        // when the face went with the link -- the difference being that now the tab has something to draw while it
        // waits. Without this, letting a quiet cube keep its face turned a refused click into an assignment to a
        // device nobody can hear.
        if let cubeFace, isCubeConnected {
            return isFaceLocked ? .faceIsLocked(cubeFace) : .assignToFace(cubeFace)
        }
        return isManualMode ? .startTiming : .waitingForTheDevice
    }

    /// Whether the face on show may be locked or unlocked from here.
    ///
    /// **Only a cube's face has a lock**, which is the archive's decision and its wording: manual mode's face is
    /// *meant* to be reassigned, since every category picked lands on it, so a lock there could only get in the way of
    /// the one gesture the tab has. Hidden rather than shown switched off, for the same reason -- there is no lock to
    /// offer, not a lock that happens to be open.
    static func showsLock(cubeFace: Int?) -> Bool {
        cubeFace != nil
    }
}
