import Foundation

/// Settling one setting: what happened, what the surface must do about it, and what to say.
///
/// **This is the settings-window rule in `CLAUDE.md` written once instead of eight times.** A changed field is
/// written straight through and the write is checked; the window adopts the change only once the table has it;
/// a refused write puts the row back to what is stored and says so in an alert. Every writing row on the Device
/// tab did all of that for itself, and the six that reach the cube also repeated the ordering the first design
/// rule turns on.
///
/// **The ordering is the part worth enforcing rather than describing.** The cube goes first and the table is
/// written only once the cube has taken the command. Recording ahead of the send would be the app writing its
/// own wish down as the cube's state, which is exactly the two-answers fault the database rule exists for, and
/// a sequence spelled out at six call sites is a sequence one of them can spell differently.
@MainActor
package enum DeviceSettingWrite {
    /// What became of one attempt to settle a setting.
    package enum Outcome: Equatable {
        /// The cube took it, if it was asked, and the table recorded it.
        case settled
        /// There was no radio, so the command could not even be sent.
        ///
        /// **A refusal rather than a quiet success.** A row left showing a number that reached neither the cube
        /// nor the table is the surface claiming something about hardware nobody ever asked.
        case nothingToSendTo
        /// The command went and the cube did not confirm it. Nothing was written.
        case refusedByTheCube
        /// The cube took it and the table would not. The two now disagree until this is set again.
        case notRecorded
        /// There is no settings store at all, which is a launch with no database.
        case nowhereToRecord

        /// Whether the surface has to put its row back to what the table holds.
        ///
        /// **Everything except `settled`**, and on `settled` it must *not*: by the time a write has been made
        /// and read back, the field may hold a newer number with a write of its own already queued, and
        /// assigning this one would take that edit off the screen.
        package var putsTheRowBack: Bool { self != .settled }
    }

    /// What to say about an outcome, or `nil` where there is nothing to say.
    ///
    /// - Parameter setting: how the setting is named to a person, mid-sentence and **carrying its own
    ///   article**: "the auto-pause delay", "the LED brightness". Every message below drops it mid-sentence
    ///   for that reason. The two helpers this replaced took two different noun forms, one bare and one
    ///   with the article, and folding them onto one parameter while passing the article form produced
    ///   "The the auto-pause delay was sent to the device" on every refusal.
    package static func notice(for outcome: Outcome, setting: String) -> Dialogue? {
        switch outcome {
        case .settled:
            return nil

        // **Silent, and deliberately.** With nothing connected there is no command to send and the row simply
        // goes back, which is the same answer every other writing row gives. Saying it in an alert would be
        // telling somebody their cube is not connected, which the tab already shows.
        case .nothingToSendTo:
            return nil

        case .refusedByTheCube:
            return Dialogue(
                title: "The TimeFlip did not accept that",
                message: """
                The device did not confirm \(setting), so nothing has changed and the window has gone back to \
                what is stored.

                This usually means the device is out of range or busy. Trying again is safe.
                """
            )

        // Rarer than the above and worse, so it says plainly that the two now disagree and which one the app
        // will believe next time.
        case .notRecorded:
            return Dialogue(
                title: "That setting was not saved",
                message: """
                The TimeFlip accepted \(setting), but the database would not record it, so the window has gone \
                back to what is stored.

                The device and the app now disagree until the next time this is set. Trying again is safe.
                """
            )

        case .nowhereToRecord:
            return Dialogue(
                title: "That setting was not saved",
                message: """
                The database would not take the new value for \(setting), so the setting is unchanged and the \
                row has gone back to what is stored.

                Nothing else has been affected. Trying again is safe.
                """
            )
        }
    }

    /// Sends a command and records the value **only once the cube has taken it**.
    ///
    /// **The rows this writes keep the wording each row already had**, which is not cosmetic: they are read
    /// back out of `debug_log` by SQL `LIKE` patterns in `Tests/Scripted`, so a generalisation that tidied
    /// them would break checks that are set aside and cannot say so. The scheme every one of them already
    /// followed is `label: verb value`, and that is what `label` and `value` are for.
    ///
    /// - Parameter send: the radio, or `nil` where there is none. Answers whether the cube took the command,
    ///   which for a command with a read-back means confirmed and for one without means acknowledged. Which of
    ///   those it is belongs to whoever built the command, and `docs/timeflip.md` carries the matrix.
    /// - Parameter tookIt: the row to write when the cube takes it, or `nil` for the callers that write none.
    ///   The LED pair pass one, because "acknowledged" is the honest word there and somebody reading the log
    ///   for a light that did not change has to be able to see that nothing ever checked.
    /// - Parameter record: writes the value to the table and answers whether the table took it. Called only
    ///   after the cube has, which is the whole point of this function.
    /// - Parameter settled: the outcome, exactly once.
    package static func send(
        _ command: Data,
        _ label: String,
        value: String,
        through send: ((Data, @escaping (Bool) -> Void) -> Void)?,
        tookIt: String? = nil,
        recording record: @escaping () -> Bool,
        debugLog: DebugLog?,
        then settled: @escaping (Outcome) -> Void
    ) {
        guard let send else {
            debugLog?.record(.field, "\(label): there is no radio to send to, so \(value) goes back")
            settled(.nothingToSendTo)
            return
        }
        debugLog?.record(.field, "\(label): sending \(value)")
        send(command) { took in
            guard took else {
                debugLog?.record(.field, "\(label): the cube did not take \(value), so the window goes back")
                settled(.refusedByTheCube)
                return
            }
            if let tookIt { debugLog?.record(.field, tookIt) }
            settled(record() ? .settled : .notRecorded)
        }
    }

    /// Records a setting the cube is never told about, where the table taking it is the whole of the write.
    ///
    /// The Device tab has two of these, the pause-on-lock box and the battery warning level: no command
    /// carries either, so there is nothing to send and nothing to confirm.
    package static func record(
        _ label: String,
        value: String,
        into store: SettingStore?,
        recording record: (SettingStore) -> Bool,
        debugLog: DebugLog?
    ) -> Outcome {
        guard let store else {
            debugLog?.record(.field, "\(label): there is no settings store, so \(value) goes back")
            return .nowhereToRecord
        }
        let stored = record(store)
        debugLog?.record(
            .field,
            stored ? "\(label): the table now holds \(value)" : "\(label): the table REFUSED \(value)"
        )
        return stored ? .settled : .nowhereToRecord
    }
}
