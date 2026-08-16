/// The developer flag: whether this is a developer build.
///
/// Compile-time and nothing else. What it gates is decided by whatever needs gating, when there is
/// something to gate.
enum DeveloperMode {
    static let isEnabled = true

    /// The PIN a developer build offers after the vendor default, and `nil` in any other build.
    ///
    /// **It is the archive's own dev PIN**, and it is here for a cube that exists rather than for a case that might:
    /// the previous app rotated a cube's PIN on pairing, to `123456` in a developer build
    /// (`Archive/TimeFlipApp/DeveloperConfigStore.swift`), so the hardware this rebuild is tested against is very
    /// likely sitting on that value right now. Without it a dev build cannot reach its own test cube.
    ///
    /// **A stand-in for the stored PIN, never a candidate alongside one.** That distinction is the archive's, and it
    /// cost it a real bug: offered as a *third* guess it let a dev build into a cube whose PIN the app had no record
    /// of, and made "the stored PIN" mean two different things (fixed 2026-08-11). Nothing in this app stores a PIN
    /// yet, because nothing sets one -- when rotation arrives, what it stores takes this slot.
    static var devicePIN: String? { isEnabled ? "123456" : nil }
}
