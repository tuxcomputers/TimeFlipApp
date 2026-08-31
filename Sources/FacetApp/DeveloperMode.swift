/// The developer flag: whether this is a developer build.
///
/// Compile-time and nothing else. What it gates is decided by whatever needs gating, when there is
/// something to gate.
enum DeveloperMode {
    static let isDeveloperMode = true

    /// **The PIN a cube is put on is `DevicePINRules`' question now**, not this file's.
    ///
    /// `devicePIN` used to live here and answer `nil` in any build but a developer's, which is how a release build
    /// came to leave every cube on the public vendor default: setting a random PIN is only safe once there is
    /// somewhere durable to keep it, and there was nowhere. `DevicePINStore` is that somewhere, so the gate moved to
    /// the one place that asks it -- `DevicePINRules.target`, which reads this flag and answers `123456` for a
    /// developer build and six random digits for any other.
}
