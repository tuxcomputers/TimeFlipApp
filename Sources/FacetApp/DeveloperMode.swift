/// The developer flag: whether this is a developer build.
///
/// Compile-time and nothing else. What it gates is decided by whatever needs gating, when there is
/// something to gate.
enum DeveloperMode {
    static let isDeveloperMode = true

    /// The one PIN a developer build ever puts on a cube, and `nil` in any other build.
    ///
    /// **It is the archive's own dev PIN**, and it is here for a cube that exists rather than for a case that might:
    /// the previous app rotated a cube's PIN on pairing, to `123456` in a developer build
    /// (`Archive/TimeFlipApp/DeveloperConfigStore.swift`), so the hardware this rebuild is tested against is very
    /// likely sitting on that value right now. Without it a dev build cannot reach its own test cube.
    ///
    /// It has two jobs, and they are the same value on purpose. It is **what a cube gets set to** once it has let the
    /// app in (`DeviceLoginRules.rotation`), fixed rather than random so a dev cube's PIN is always known and
    /// typeable if anything goes wrong. And it **stands in as the stored PIN when `config.json` names none**, which
    /// is the other half of that: with nothing written down, a dev build can still reach a cube on either `000000` or
    /// this, the only two values a dev cube is ever left on.
    ///
    /// **A stand-in for the stored PIN, never a candidate alongside one.** That distinction is the archive's, and it
    /// cost it a real bug: offered as a *third* guess it let a dev build into a cube whose PIN the app had no record
    /// of, and made "the stored PIN" mean two different things (fixed 2026-08-11).
    ///
    /// **`nil` is what stops any other build touching a cube's PIN**, and that is deliberate rather than unfinished.
    /// A production build would set six random digits, which is only safe once there is somewhere durable to keep
    /// them -- the archive used the Keychain, and this app has no such store yet. Setting a PIN it cannot write down
    /// would lock the cube out of every app including this one, so until that store exists a non-developer build
    /// leaves the cube on whatever PIN let it in.
    static var devicePIN: String? { isDeveloperMode ? "123456" : nil }
}
