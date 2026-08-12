/// The developer flag: whether this is a developer build.
///
/// Compile-time and nothing else. What it gates is decided by whatever needs gating, when there is
/// something to gate.
enum DeveloperMode {
    static let isEnabled = true
}
