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

    /// **There is no `putBack` property, and there was one until 2026-09-18.** It was a single closure for the
    /// whole pane, set once, and the Mac could not adopt it: its rows deliberately do not reload, each having a
    /// `show*` for putting one refused row back and a `record*` for updating its own copy after a write that
    /// landed -- because a field stepped again while a write was in flight holds a newer number with a write of
    /// its own already queued, and reloading would take that edit off the screen. The LED rows are debounced, so
    /// two writes really can be out at once.
    ///
    /// **Every method reports its outcome instead**, which is `handover-linux.md` item 39's second option and the
    /// one to take: it is the shape `AppSettingWrite.apply` already has, that one adopted on the Mac in four lines
    /// where this module did not adopt at all, and the outcome is a value rather than a stored property two
    /// overlapping writes would fight over. What to do about a refusal is then the surface's, which is where the
    /// difference between the two panes actually lives.

    /// The settings sync, bracketed around every write that reaches the cube.
    ///
    /// **What it is for is the correction loop in item 25 of `docs/linux-port.md`**: the `0x10` that confirms a
    /// write arrives at the sync like any other status, at the one moment the table still holds the old value, so
    /// the sync used to correct the cube back to it. Telling it a write is out is what stops the question being
    /// asked mid-write.
    ///
    /// **Only the three that reach the cube are bracketed**, because only they produce a confirmation read. The
    /// pause-on-lock box and the battery warning send nothing, so nothing comes back to be misread.
    package var settingsSync: DeviceSettingsSync?

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
    package func pauseOnLock(
        _ pausesOnLock: Bool,
        then settled: (@MainActor (DeviceSettingWrite.Outcome) -> Void)? = nil
    ) {
        settle(
            DeviceSettingWrite.record(
                "Pause on lock",
                value: pausesOnLock ? "on" : "off",
                into: settings,
                recording: { $0.write("pause_on_lock", field: "enabled", pausesOnLock) },
                debugLog: debugLog
            ),
            setting: "the pause-on-lock setting",
            then: settled
        )
    }

    /// What counts as the cube running flat.
    package func batteryWarning(
        _ percent: Int,
        then settled: (@MainActor (DeviceSettingWrite.Outcome) -> Void)? = nil
    ) {
        let outcome = DeviceSettingWrite.record(
            "Battery warning",
            value: "\(percent) percent",
            into: settings,
            recording: { $0.write("low_battery_level", field: "percent", percent) },
            debugLog: debugLog
        )
        guard settle(outcome, setting: "the battery warning level", then: settled) else { return }
        lowBattery?.reconsider(because: "the warning level changed")
    }

    // MARK: - the three that reach the cube

    /// How long the cube waits before pausing itself.
    ///
    /// **Confirmed rather than merely acknowledged**, which is where this is stronger than the LED pair: `0x10`
    /// reports the delay the cube is set to, so the read-back compares the cube's own answer against the bytes that
    /// went out.
    package func autoPause(
        _ minutes: Int,
        then settled: (@MainActor (DeviceSettingWrite.Outcome) -> Void)? = nil
    ) {
        settingsSync?.writeBegan(.autoPause)
        DeviceSettingWrite.send(
            DeviceCommandRules.autoPause(minutes),
            "Auto-pause",
            value: "\(minutes)m",
            through: send,
            recording: { [weak self, debugLog] in
                // **Gone means say so.** A module nobody retained is deallocated while the command is in flight,
                // and returning false here without a row is a write that reports nothing at all: no table row,
                // no notice, and no put-back. Scripted run 187 spent nineteen minutes finding that shape on the
                // LED row, where it read as the table write simply never happening.
                guard let self else {
                    debugLog?.record(
                        .field,
                        "Auto-pause: the settings rows were released mid-write, so \(minutes)m is not recorded"
                    )
                    return false
                }
                let stored = settings.write("auto_pause_minutes", field: "minutes", minutes)
                debugLog?.record(
                    .field,
                    stored ? "Auto-pause: the table now holds \(minutes)m" : "Auto-pause: the table REFUSED \(minutes)m"
                )
                return stored
            },
            debugLog: debugLog
        ) { [weak self] outcome in
            // **Ended before the outcome is reported**, so the bracket is closed whatever a surface does next: a
            // caller that reloads its rows from the table inside `settled` would otherwise do it while this app
            // still claimed to be writing.
            self?.settingsSync?.writeEnded(.autoPause)
            _ = self?.settle(outcome, setting: "the auto-pause delay", then: settled)
        }
    }

    /// How brightly the cube lights its face.
    ///
    /// **The word rather than the sign**, and it is the same hazard as an apostrophe: these rows are read back out
    /// of `debug_log` by SQL `LIKE` patterns, where a literal `%` is the wildcard.
    package func ledBrightness(
        _ percent: Int,
        then settled: (@MainActor (DeviceSettingWrite.Outcome) -> Void)? = nil
    ) {
        led(percent, named: "brightness", unit: "percent", field: "brightness",
            command: DeviceCommandRules.ledBrightness(percent), then: settled)
    }

    /// How often it blinks.
    package func ledBlink(
        _ seconds: Int,
        then settled: (@MainActor (DeviceSettingWrite.Outcome) -> Void)? = nil
    ) {
        led(seconds, named: "blink interval", unit: "sec", field: "blink_interval",
            command: DeviceCommandRules.ledBlink(seconds), then: settled)
    }

    /// The pair, which differ only in the three words and the field.
    ///
    /// **Acknowledged is the honest word**, and the row says so: the vendor spec defines no read-back for either, so
    /// somebody reading the log for a light that did not change has to be able to see that nothing ever checked.
    private func led(
        _ value: Int,
        named what: String,
        unit: String,
        field: String,
        command: Data,
        then settled: (@MainActor (DeviceSettingWrite.Outcome) -> Void)?
    ) {
        DeviceSettingWrite.send(
            command,
            "LED",
            value: "\(what) \(value) \(unit)",
            through: send,
            // **The Mac's wording, restored 2026-09-18 and not a preference.** `63-led-settings.sh` check 8 matches
            // this row in full, and it needs a cube -- so a module written on the other box cannot reword it and
            // find out. The clause this replaced, *which is all this command can be asked*, said the same thing and
            // would have failed that check the first time anybody ran it.
            tookIt: "LED: the cube acknowledged \(what) \(value) \(unit), and there is no read-back to confirm it with",
            recording: { [weak self, debugLog] in
                // Gone means say so, for the reason `autoPause` gives: this is the row run 187 failed on.
                guard let self else {
                    debugLog?.record(
                        .field,
                        "LED: the settings rows were released mid-write, so \(what) \(value) \(unit) is not recorded"
                    )
                    return false
                }
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
            _ = self?.settle(outcome, setting: "the LED \(what)", then: settled)
        }
    }

    // MARK: - the eighth row, and the odd one

    /// The device's own name.
    ///
    /// **The odd one on this tab, and it is odd in four ways that all come from one fact**: the name is what a scan
    /// filters on (`DeviceScanRules.isEligible`), so a name that reached neither the cube nor the table is not a
    /// stale row, it is an app that may not find its cube again.
    ///
    /// 1. **It speaks on success**, which no other row does: the cube keeps advertising the old name until it is
    ///    power-cycled, so somebody who renamed it and then watched a scan would think nothing happened.
    /// 2. **It speaks where `nothingToSendTo` is silent everywhere else**, for the reason above.
    /// 3. **It announces itself in its own words.** `Renaming the cube to <name>` replaces the default
    ///    `label: sending value`, because `Tests/Scripted/66-device-rename.sh` matches that row in full and reads
    ///    its row id to prove the table was written after the cube. `DeviceSettingWrite.send`'s `announcing` is
    ///    there for this one caller; the default scheme is the interface for everything else.
    /// 4. **The row is re-read on every outcome, success included**, where the other five leave a field alone that
    ///    landed. The Name field has committed and closed itself by then, and on success the new name is exactly
    ///    what the row should start showing.
    ///
    /// - Parameter current: what the surface is showing, which is what the table said when it was drawn. It is used
    ///   only to spot a name that did not change and to word the success notice; the name that matters is the one
    ///   going to the cube.
    /// - Returns, through `settled`: what to tell somebody, or `nil` when there is nothing to say -- and the caller
    ///   re-reads its row either way.
    package func rename(
        to typed: String,
        replacing current: String?,
        then settled: (@MainActor (Dialogue?) -> Void)? = nil
    ) {
        switch DeviceNameRules.renameDecision(typed: typed, current: current) {
        case .ignore:
            // The field has closed itself, and an alert saying nothing happened would be worse than nothing
            // happening.
            debugLog?.record(.field, "The device name was left as it was")
            settled?(nil)
        case let .refuse(problem):
            debugLog?.record(.field, "The device cannot be called \(typed): \(problem.title)")
            settled?(Dialogue(title: problem.title, message: problem.message))
        case let .write(name):
            send(name, replacing: current, then: settled)
        }
    }

    private func send(
        _ name: String,
        replacing previous: String?,
        then settled: (@MainActor (Dialogue?) -> Void)?
    ) {
        guard let command = DeviceCommandRules.setName(name) else {
            // A name the command itself cannot carry. `renameDecision` has already refused the names that are
            // unsendable for a reason worth naming, so this is the residue, and `writeFailed` is the notice worded
            // for it: it does not quote the character rules, which would send somebody looking in the wrong place.
            //
            // **Its own guard rather than one branch with the missing radio.** The two say one thing on screen and
            // different things in the log, which is the gain -- a row reading that there was no radio is a
            // different diagnosis from one reading that the name would not fit in a command.
            debugLog?.record(.field, "The name \(name) could not be sent to the cube")
            settled?(Self.notice(.writeFailed))
            return
        }
        DeviceSettingWrite.send(
            command,
            "The device name",
            value: name,
            through: send,
            announcing: "Renaming the cube to \(name)",
            recording: { [weak self] in
                guard let self else { return false }
                return DevicePairingRecorder(settings: settings, debugLog: debugLog)
                    .recordName(name, because: "renamed from the Device tab")
            },
            debugLog: debugLog
        ) { outcome in
            switch outcome {
            case .settled:
                settled?(Dialogue(
                    title: "The TimeFlip has been renamed",
                    message: DeviceNameRules.renameLagNotice(newName: name, previousName: previous)
                ))
            case .nothingToSendTo, .refusedByTheCube:
                // **One notice for both on purpose**: each means nothing reached the cube, which is what
                // `writeFailed` is worded for.
                settled?(Self.notice(.writeFailed))
            case .notRecorded, .nowhereToRecord:
                // The cube took it and the table did not. The surface follows the table, that being what the next
                // open reads.
                settled?(Dialogue(
                    title: "That setting was not saved",
                    message: """
                    The TimeFlip took the new name and this app could not write it down, so it will be sent again \
                    the next time they are connected.
                    """
                ))
            }
        }
    }

    private static func notice(_ problem: DeviceNameProblem) -> Dialogue {
        Dialogue(title: problem.title, message: problem.message)
    }

    /// Says why a write did not land if there is something to say, and hands the outcome on.
    ///
    /// **The notice is this module's and the row is the surface's**, which is the split item 39 settled: what a
    /// refusal is *called* has to be the same on both platforms, and what a refusal *does to a control* is the
    /// difference between a pane that reloads and one that puts one field back.
    ///
    /// **The outcome is reported after the notice**, so a surface that puts a row back does it behind a dialogue
    /// that is already up rather than in front of one about to be.
    ///
    /// - Returns: whether the write landed, for the one caller that has something to do afterwards.
    @discardableResult
    private func settle(
        _ outcome: DeviceSettingWrite.Outcome,
        setting: String,
        then reported: (@MainActor (DeviceSettingWrite.Outcome) -> Void)?
    ) -> Bool {
        if let notice = DeviceSettingWrite.notice(for: outcome, setting: setting) {
            dialogues.tell(notice)
        }
        reported?(outcome)
        return outcome == .settled
    }
}
