import Foundation

/// Puts `ForcedPause`'s decision on the wire.
///
/// **`ForcedPause` decides and this acts**, the split `DailyLimitWatch` uses and for its reasons: the decision is
/// covered without a radio, and what "stop the cube" means is handed in rather than known here.
///
/// **Driven by events, not by a tick.** There are exactly two moments the answer can change, and both already have a
/// funnel:
///
/// - **A history event arrives** (`HistoryIngestor.onChanged`). The cube has been turned, or its record has moved, so
///   which face it is resting on and whether it is stopped are both freshly written. A flip is prompt rather than
///   waiting out `fetch_history_interval_seconds`: the faces characteristic notifies and the app fetches on it.
/// - **A face is given a category** (`SettingsWindowController.onTimingChanged`). Nothing physical happens here, so
///   there is no history event to ride on and no other way this would ever be noticed.
///
/// A tick would be the wrong shape. The cube volunteers nothing between those two, so a second-by-second read of the
/// same two tables would answer the same thing every time until one of them fired anyway.
///
/// **Everything is read at the moment it is needed**, per the first rule in `CLAUDE.md`. Nothing is held between
/// looks except the enforcement's claim, which is not a copy of any row -- see its own note.
@MainActor
final class ForcedPauseWatch {
    /// The face the cube's open segment names, or `nil` for a cube with no open segment to read.
    private let openFace: () -> Int?

    /// Whether that face holds a category, read from `face` at the moment of the ask.
    private let hasCategory: (Int) -> Bool

    /// Whether the cube is stopped, from the open `device_event` row -- the cube's own account.
    private let isPaused: () -> Bool?

    /// Whether the cube is locked, from `BluetoothRadio.cubeStatus`.
    private let isLocked: () -> Bool?

    /// Whether there is a live link to send anything down.
    private let isConnected: () -> Bool

    /// Whether `DailyLimitEnforcement` is holding a pause of its own, so a hard limit is not lifted by this.
    private let limitIsHolding: () -> Bool

    /// Stops the cube or starts it. `CubeLock.setPause`, handed in rather than held, so both sequences can be driven
    /// in a test with no radio. Answers whether anything was sent: `false` means the completion will not be called.
    private let setPause: (Bool, @escaping (Bool) -> Void) -> Bool

    /// Goes and asks what the cube now says. **Not tidying up: it is the only way the app finds out.** Measured
    /// 2026-08-27 (finding 9 in `docs/timeflip2-firmware-observations.md`) -- a pause files a new history event on the
    /// cube and the cube announces nothing at all.
    private let refreshHistory: (String, @escaping () -> Void) -> Void

    private let debugLog: DebugLog?

    /// The decision, and the only thing here that remembers anything.
    private var enforcement = ForcedPause()

    /// **A command is out and the tables have not caught up with it yet.**
    ///
    /// Without this the driver re-enters itself and sends the pause twice. The window is real rather than theoretical:
    /// `device_event` goes on saying the cube is running until the fetch that follows the pause lands, and that fetch
    /// is itself what calls `check` again -- so the second look sees a running cube on a face with no category and
    /// asks for another pause.
    ///
    /// **And the claim cannot stand in for it**, which is why this is a flag rather than something derived. "Claimed
    /// face, table says running" is exactly what a *hand-resume* on that face looks like too, and that case
    /// deliberately does pause again. The two are indistinguishable from the tables; only knowing a command is
    /// currently in flight tells them apart.
    private var isSending = false

    init(
        openFace: @escaping () -> Int?,
        hasCategory: @escaping (Int) -> Bool,
        isPaused: @escaping () -> Bool?,
        isLocked: @escaping () -> Bool?,
        isConnected: @escaping () -> Bool,
        limitIsHolding: @escaping () -> Bool,
        setPause: @escaping (Bool, @escaping (Bool) -> Void) -> Bool,
        refreshHistory: @escaping (String, @escaping () -> Void) -> Void,
        debugLog: DebugLog?
    ) {
        self.openFace = openFace
        self.hasCategory = hasCategory
        self.isPaused = isPaused
        self.isLocked = isLocked
        self.isConnected = isConnected
        self.limitIsHolding = limitIsHolding
        self.setPause = setPause
        self.refreshHistory = refreshHistory
        self.debugLog = debugLog
    }

    /// One look. Internal so a test can call it in place of the funnels.
    func check() {
        guard !isSending else { return }

        let face = openFace()
        let action = enforcement.evaluate(
            face: face,
            hasCategory: face.map { hasCategory($0) } ?? false,
            isPaused: isPaused() ?? false,
            isLocked: isLocked(),
            isConnected: isConnected(),
            limitIsHolding: limitIsHolding()
        )

        switch action {
        case .none:
            return

        case .pause:
            // `evaluate` answers `.pause` only for a face it was given, so this cannot be reached with `nil`. Written
            // as a guard rather than a force so a future change to the decision cannot turn into a crash here.
            guard let face else { return }
            debugLog?.record(.forced, "Forced pause: face \(face) has no category, so the cube is being stopped")
            send(true, claiming: face, because: "the cube was stopped on a face with no category")

        case .resume:
            debugLog?.record(.forced, "Forced pause lifted: the face has a category now, so the cube is being started")
            send(false, claiming: nil, because: "the cube was started once its face had a category")
        }
    }

    /// Sends one command, claims it only if the cube confirms it, and then goes and asks what the cube says.
    private func send(_ wanted: Bool, claiming face: Int?, because reason: String) {
        isSending = true
        let sent = setPause(wanted) { [weak self] took in
            guard let self else { return }
            if took {
                // **Claimed on the confirmation, not on the asking.** Every command goes out through `CubeLock`, which
                // reads it back before believing it, and claiming at the moment of asking would leave this holding a
                // pause the cube never made.
                if let face {
                    self.enforcement.pauseTook(onFace: face)
                } else {
                    self.enforcement.resumeTook()
                }
            }
            self.refreshHistory(reason) { [weak self] in
                // **Cleared only once the fetch has written**, which is the whole point of the flag: cleared at the
                // command's own completion instead, the very next `onChanged` would still be reading a table that says
                // the cube is running.
                self?.isSending = false
            }
        }
        // Nothing was sent, so nothing will complete and nothing is in flight. `CubeLock` answers `false` for a cube
        // that is not connected or is locked, both of which it has already said in the log.
        if !sent { isSending = false }
    }
}
