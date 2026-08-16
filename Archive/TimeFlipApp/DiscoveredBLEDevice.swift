import Foundation

struct DiscoveredBLEDevice: Identifiable, Equatable, Sendable {
    let id: UUID
    let name: String
}

/// A device a startup scan judged this app could plausibly be paired to: the vendor name, or the
/// name it remembers, or the one before that (`TimeFlipBLEDevice.scanForEligibleDevices`).
///
/// Eligible is not the same as *this user's*. Several TimeFlips in the same office are all eligible
/// and only one will accept this app's PIN, which is the whole reason the caller works through the
/// list rather than trusting the first answer.
struct EligibleDevice: Identifiable, Equatable, Sendable {
    let id: UUID
    let name: String

    /// The order to try candidates in: the paired device first, then everything else by name.
    ///
    /// Ordering, not filtering, and the distinction is the whole point. The uuid is assigned by
    /// this Mac's CoreBluetooth stack, so when it is present it is the surest identification going
    /// and belongs first, making the ordinary case cost exactly one login attempt. But a cube that
    /// was re-paired, reset, or paired on another Mac can legitimately no longer carry it and still
    /// be the user's own device, so it must not be the only one tried. Filtering on it would trade
    /// today's bug (connect to a stranger's cube) for tomorrow's (never find your own again).
    ///
    /// The remainder is sorted by name so two scans of the same room produce the same order; a
    /// dictionary's iteration order does not.
    static func ordered(_ found: [EligibleDevice], preferring pairedUUID: UUID?) -> [EligibleDevice] {
        let byName = found.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        guard let pairedUUID else { return byName }
        return byName.filter { $0.id == pairedUUID } + byName.filter { $0.id != pairedUUID }
    }
}
