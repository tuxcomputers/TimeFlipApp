import Foundation

/// What the two surfaces that warn about a flat cube are drawing at this instant.
///
/// Two facts rather than one, because they answer different questions: `isBatteryLow` is whether the warning stands, and
/// `isBlinkOn` is which half of the flash is currently up. A screen reader wants the first and a colour wants the
/// second.
struct LowBatteryAlert: Equatable {
    /// Whether the level has dropped to the warning level and not yet climbed back out of it.
    let isBatteryLow: Bool

    /// Whether the blink is on its coloured phase. Never true unless `isBatteryLow` is.
    let isBlinkOn: Bool

    /// Nothing to warn about: no cube, or a cube with charge in it.
    static let none = LowBatteryAlert(isBatteryLow: false, isBlinkOn: false)
}

/// The low-battery warning: whether it stands, and the flash that carries it.
///
/// **One owner for both surfaces.** The menu bar's category name and the Device tab's Battery row blink together,
/// and they can only do that if one object decides when. Two blinkers would be two answers to "is the warning up",
/// which is exactly the disagreement the first rule in `CLAUDE.md` is about -- and here it would be visible, as two
/// things on screen flashing out of step.
///
/// **It holds no copy of the level.** The charge is a fact about the live connection and `BluetoothRadio` owns it, so
/// this asks for it at the moment it needs it. The one thing held is the latch itself, which is not a copy of anything:
/// hysteresis *is* memory of what was decided last, and there is nowhere else that answer exists.
///
/// **The threshold is read from the table every time it is asked**, not at launch and not when the window that edits
/// it closes. Somebody moving `low_battery_level` from 10 to 20 with the App tab open has changed what counts as low
/// from that moment, and `SettingsWindowController` says so by calling `reconsider` once the write has been read back.
///
/// Massaged from the archive's `MenuBarController.updateLowBatteryBlinkTimer` and `setLowBatteryBlinkState`: same
/// half-second flash, same latch, same reason for both. What is not kept is where they lived -- the archive spread the
/// latch, the timer, the threshold and a mirror of the whole state across `MenuBarController` and `AppState`, so the
/// Settings window learned about the blink by being told about it twice.
@MainActor
final class LowBatteryWatch {
    /// How long each half of the flash lasts.
    ///
    /// **The archive's half-second, copied**, and its note on why is worth keeping: deliberately faster than the
    /// menu bar's one-second tick, so it reads as something demanding attention rather than as part of the clock.
    static let blinkSeconds: TimeInterval = 0.5

    /// The level on show, asked for rather than remembered. `nil` when there is no live reading, which is every
    /// moment there is no cube on the other end.
    private let level: @MainActor () -> Int?

    private let settings: SettingStore?
    private let debugLog: DebugLog?

    /// Called whenever what should be on screen changes: the warning arming or clearing, and every half-second while
    /// it is up. Whoever draws asks for `alert` when it fires.
    var onChanged: (@MainActor () -> Void)?

    private var isBatteryLow = false
    private var isBlinkOn = false
    private var blink: Timer?

    /// What to draw, now.
    var alert: LowBatteryAlert { LowBatteryAlert(isBatteryLow: isBatteryLow, isBlinkOn: isBlinkOn) }

    init(level: @escaping @MainActor () -> Int?, settings: SettingStore?, debugLog: DebugLog?) {
        self.level = level
        self.settings = settings
        self.debugLog = debugLog
    }

    /// Works out whether the warning stands, and starts or stops the flash to match.
    ///
    /// Called on every reading the cube pushes, when a link goes, and when the warning level itself is changed.
    /// **All three, because any of them can change the answer** -- and the third is the one a reading-driven watch
    /// would miss for as long as the cube's charge held steady, which on this hardware is hours.
    ///
    /// - Parameter reason: what prompted this, for the log. Only written when the verdict actually moves.
    func reconsider(because reason: String) {
        let before = alert
        let level = level()
        // Read here, at the point of use. `SettingStore` answers `nil` for a missing or malformed row and refuses to
        // guess what absence means, so the fallback is the seed the DDL itself writes.
        let threshold = settings?.integer("low_battery_level", field: "percent")
            ?? BatteryRules.defaultWarningPercent
        isBatteryLow = BatteryRules.latched(isBatteryLow, level: level, threshold: threshold)

        if isBatteryLow != before.isBatteryLow {
            debugLog?.record(
                .battery,
                isBatteryLow
                    ? "Low battery: \(level.map(String.init) ?? "?")% at or below \(threshold)%,"
                        + " clearing above \(threshold + BatteryRules.recoveryMargin)% (\(reason))"
                    : "Battery recovered: \(level.map(String.init) ?? "?")% is above"
                        + " \(threshold + BatteryRules.recoveryMargin)% (\(reason))"
            )
        }

        // **The flash stops with the link, the warning does not.** There is nothing on screen to flash about while
        // the Battery row reads "Unknown", and a menu bar blinking about a cube nobody can hear from is a warning
        // about a charge the app cannot confirm. The latch survives, so a cube that comes back still flat is still
        // flat rather than newly discovered.
        if isBatteryLow, level != nil {
            startBlinking()
        } else {
            stopBlinking()
        }
        if alert != before { onChanged?() }
    }

    /// Stops the flash and lets go of the timer.
    ///
    /// **Nothing in the app calls this**, and that is not an oversight: the warning lasts as long as the process, and
    /// there is no moment in a launch where it should stop being drawn while a flat cube is still connected. The tests
    /// call it, so a repeating timer does not outlive the case that started it.
    func stop() {
        stopBlinking()
    }

    private func startBlinking() {
        guard blink == nil else { return }
        // On its coloured phase to begin with, so the warning arrives as a colour rather than as half a second of
        // nothing.
        isBlinkOn = true
        let timer = Timer(timeInterval: Self.blinkSeconds, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.isBlinkOn.toggle()
                self.onChanged?()
            }
        }
        // `.common`, for the reason every timer in this app uses it: the default mode stops dead while a menu is
        // tracking, and this item's own dropdown is one of them -- so the warning would freeze in exactly the second
        // somebody has the menu open in front of it.
        RunLoop.main.add(timer, forMode: .common)
        blink = timer
    }

    private func stopBlinking() {
        blink?.invalidate()
        blink = nil
        isBlinkOn = false
    }
}
