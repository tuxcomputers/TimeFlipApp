import Foundation

/// The five rows of the Device tab's Settings section: what each one writes, in what order, and what it says.
///
/// **`DeviceSettingWrite` is the ordering and this is the five callers of it.** That module holds the sequence the
/// first design rule turns on -- the cube first, the table only once the cube has taken it -- and knows nothing
/// about which settings exist. This names them: the command each sends, the row each writes, the wording each is
/// logged and refused under, and which two send nothing at all.
///
/// **Two of the five send nothing, and that is not an oversight.** Pause on lock says what the app does to the cube
/// when it locks it (`CubeLock.lock` reads `pause_on_lock` at the step that needs it) and the battery warning says
/// what the app treats as flat (`LowBatteryWatch` reads `low_battery_level` every time it judges a reading), so for
/// both the whole of the write is the table taking it.
///
/// **Two of the three that do send cannot be confirmed**, which the call sites say out loud: the vendor spec defines
/// no read-back for LED brightness or the blink interval (`docs/timeflip.md`, *Confirming a command actually took
/// effect*), so the write is genuinely all there is. Auto-pause is the one that can be: `0x10` reports the delay the
/// cube is set to, so the cube's own answer is compared against what went out.
///
/// **A refused write puts the row back from the table, read at that moment.** Never from what the caller asked for
/// and never from a copy: a write has just failed, so what is stored is precisely the question being asked.
@MainActor
package final class DeviceSettingRows {
    private let settings: SettingStore
    private let dialogues: DialoguePresenter
    private let debugLog: DebugLog?

    /// The radio, or `nil` where there is none. **A closure rather than a device**, so the core states what it needs
    /// and nothing here knows whether it is CoreBluetooth or BlueZ underneath.
    package var send: ((Data, @escaping (Bool) -> Void) -> Void)?

    /// Put the rows back to what the table holds. Called only when a write did not land, which is when the screen
    /// and the database would otherwise disagree.
    package var putBack: (@MainActor () -> Void)?

    /// The low-battery watch, told to think again when the level changes.
    ///
    /// **Nothing else would ask it.** The warning is worked out when a reading arrives, and a cube whose charge is
    /// steady may not report one for over an hour -- so somebody raising the level from 10 to 20 with a cube sitting
    /// at 15 would watch a control that appeared to do nothing.
    package var lowBattery: LowBatteryWatch?

    package init(settings: SettingStore, dialogues: DialoguePresenter, debugLog: DebugLog?) {
        self.settings = settings
        self.dialogues = dialogues
        self.debugLog = debugLog
    }

    // MARK: - the two that send nothing

    /// Whether locking the cube should pause it first.
    package func pauseOnLock(_ pausesOnLock: Bool) {
        settle(
            DeviceSettingWrite.record(
                "Pause on lock",
                value: pausesOnLock ? "on" : "off",
                into: settings,
                recording: { $0.write("pause_on_lock", field: "enabled", pausesOnLock) },
                debugLog: debugLog
            ),
            setting: "the pause-on-lock setting"
        )
    }

    /// What counts as the cube running flat.
    package func batteryWarning(_ percent: Int) {
        let outcome = DeviceSettingWrite.record(
            "Battery warning",
            value: "\(percent) percent",
            into: settings,
            recording: { $0.write("low_battery_level", field: "percent", percent) },
            debugLog: debugLog
        )
        guard settle(outcome, setting: "the battery warning level") else { return }
        lowBattery?.reconsider(because: "the warning level changed")
    }

    // MARK: - the three that reach the cube

    /// How long the cube waits before pausing itself.
    ///
    /// **Confirmed rather than merely acknowledged**, which is where this is stronger than the LED pair: `0x10`
    /// reports the delay the cube is set to, so the read-back compares the cube's own answer against the bytes that
    /// went out.
    package func autoPause(_ minutes: Int) {
        DeviceSettingWrite.send(
            DeviceCommandRules.autoPause(minutes),
            "Auto-pause",
            value: "\(minutes)m",
            through: send,
            recording: { [weak self] in
                guard let self else { return false }
                let stored = settings.write("auto_pause_minutes", field: "minutes", minutes)
                debugLog?.record(
                    .field,
                    stored ? "Auto-pause: the table now holds \(minutes)m" : "Auto-pause: the table REFUSED \(minutes)m"
                )
                return stored
            },
            debugLog: debugLog
        ) { [weak self] outcome in
            _ = self?.settle(outcome, setting: "the auto-pause delay")
        }
    }

    /// How brightly the cube lights its face.
    ///
    /// **The word rather than the sign**, and it is the same hazard as an apostrophe: these rows are read back out
    /// of `debug_log` by SQL `LIKE` patterns, where a literal `%` is the wildcard.
    package func ledBrightness(_ percent: Int) {
        led(percent, named: "brightness", unit: "percent", field: "brightness",
            command: DeviceCommandRules.ledBrightness(percent))
    }

    /// How often it blinks.
    package func ledBlink(_ seconds: Int) {
        led(seconds, named: "blink interval", unit: "sec", field: "blink_interval",
            command: DeviceCommandRules.ledBlink(seconds))
    }

    /// The pair, which differ only in the three words and the field.
    ///
    /// **Acknowledged is the honest word**, and the row says so: the vendor spec defines no read-back for either, so
    /// somebody reading the log for a light that did not change has to be able to see that nothing ever checked.
    private func led(_ value: Int, named what: String, unit: String, field: String, command: Data) {
        DeviceSettingWrite.send(
            command,
            "LED",
            value: "\(what) \(value) \(unit)",
            through: send,
            tookIt: "LED: the cube acknowledged \(what) \(value) \(unit), which is all this command can be asked",
            recording: { [weak self] in
                guard let self else { return false }
                let stored = settings.write("led_settings", field: field, value)
                debugLog?.record(
                    .field,
                    stored
                        ? "LED: the table now holds \(what) \(value) \(unit)"
                        : "LED: the table REFUSED \(what) \(value) \(unit)"
                )
                return stored
            },
            debugLog: debugLog
        ) { [weak self] outcome in
            _ = self?.settle(outcome, setting: "the LED \(what)")
        }
    }

    /// Puts the rows back if the write did not land, and says why if there is something to say.
    ///
    /// - Returns: whether the write landed, for the one caller that has something to do afterwards.
    @discardableResult
    private func settle(_ outcome: DeviceSettingWrite.Outcome, setting: String) -> Bool {
        if outcome.putsTheRowBack { putBack?() }
        guard let notice = DeviceSettingWrite.notice(for: outcome, setting: setting) else { return true }
        dialogues.tell(notice)
        return false
    }
}
