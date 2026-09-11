import Foundation

/// Whether the cube is frozen on the face it is resting on.
///
/// **Three answers, not two, and `unknown` is a real one.** It is the cube nobody has asked yet, and it was a `Bool?`
/// read as `== true` until the state sweep: a comparison that looks like a slip and is in fact the whole decision that
/// unknown counts as unlocked. Written out, a reader can see which way each caller goes, and they do not all go the
/// same way -- `ForcedPause` deliberately requires a known `.unlocked` before it will send anything, while the menu
/// and the click router treat unknown as unlocked so that a cube nobody has asked is still operable.
///
/// The truth is `0x10`, and nothing else answers it: no history frame carries a lock bit and `device_event` has no
/// column for one.
package enum CubeLockState: Equatable {
    /// Nobody has asked, or the cube would not answer.
    case unknown
    case locked
    case unlocked

    /// From the cube's own `0x10` answer, which is absent until it has been read.
    package init(reported: Bool?) {
        switch reported {
        case .some(true): self = .locked
        case .some(false): self = .unlocked
        case nil: self = .unknown
        }
    }
}


/// Whether the cube's own clock is stopped.
///
/// **Three answers, and `unknown` is a real one**: a cube nobody has asked, and a paired cube whose history has not
/// arrived yet. This was a `Bool?` read as `== true` at four call sites, which is a comparison that looks like a slip
/// and was in fact the decision that unknown counts as running.
///
/// **Not the same question as `isCounting`**, which is whether the figure on screen is going up. A cube that has
/// flipped but whose history has not been fetched still names its new face, and the newest row for that face may be a
/// stretch that ended an hour ago, so the two are not complements. `DailyLimitEnforcement` wants the second one.
///
/// **And not the same as a segment's `isPaused`**, which is a recorded row saying it was a pause. That stays a boolean
/// on the row, matching the `paused` column: a finalised row's flag is history, while this is now.
///
/// The trap the type cannot fix: **a locked cube reports itself paused whatever its pause byte says**
/// (`DeviceCommandRules` encodes it as `isPaused: locked ? true : paused`), so a pause confirmed after a lock proves
/// nothing and pause is confirmed first.
package enum CubePauseState: Equatable {
    /// Nobody has asked, or nothing has come back yet.
    case unknown
    case paused
    case running

    package init(reported: Bool?) {
        switch reported {
        case .some(true): self = .paused
        case .some(false): self = .running
        case nil: self = .unknown
        }
    }

    /// The SF Symbol drawn for this state, and `nil` for a cube that has not said. `ManualTimerRules.symbolName`
    /// is the same idea for the app's own clock, and this is the cube's.
    ///
    /// **One answer, because it was two.** `StatusItemTitle` and `TimingView` each held this switch, identically,
    /// which is the hazard `docs/state-reference.md` opens with: one fact asked in two places, taught something
    /// in one of them, and nothing failing when they part. The menu bar and the Faces tab draw the same cube.
    ///
    /// **Nothing for `unknown`, deliberately.** A glyph for "we have not asked" would be a picture of a cube
    /// doing something, and it is not doing anything we know about.
    package var symbolName: String? {
        switch self {
        case .unknown: return nil
        case .paused: return "pause.fill"
        case .running: return "play.fill"
        }
    }

    /// What this state is called out loud, standalone: an accessibility label on its own control.
    ///
    /// **Capitalised, and its lowercase twin is below**, because the two are read in different places and only
    /// one of them starts a sentence. `Tests/Scripted/57-cube-pause` matches on this one, which makes the
    /// wording interface rather than decoration.
    package var spokenLabel: String? {
        switch self {
        case .unknown: return nil
        case .paused: return "Device paused"
        case .running: return "Device running"
        }
    }

    /// The same fact as a fragment inside a longer spoken line, which is what the menu bar builds: the status
    /// item's description is several of these joined, so this one does not start with a capital.
    package var spokenFragment: String? {
        switch self {
        case .unknown: return nil
        case .paused: return "device paused"
        case .running: return "device running"
        }
    }
}
