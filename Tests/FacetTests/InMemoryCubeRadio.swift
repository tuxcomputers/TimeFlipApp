@testable import FacetCore
import Foundation

/// A `CubeRadio` that answers whatever a test sets, and remembers what it was asked to do.
///
/// **The second conformance, which is what makes `CubeRadio` a seam rather than a description of one.**
/// `BluetoothRadio` was the only one until 2026-09-09, so the protocol passed the deletion test in
/// `docs/architecture-review-2026-09.md` candidate 2: delete it and nothing changed, because nothing used it
/// polymorphically. The split that cut it (`docs/facetcore-split.md:66`) said it was to make the reconnector
/// "testable without a radio, which it currently is not" -- and then no double was ever written, so the
/// leverage was never collected. This is it.
///
/// **Nothing here decides anything**, exactly as the protocol's own note says of the real radio. The four
/// flags are what a test wants `DeviceReconnectRules` to see; `reach` records rather than acts.
@MainActor
final class InMemoryCubeRadio: CubeRadio {
    var connectedDevice: UUID?
    var isScanning = false
    var isReachingForCube = false
    var isFactoryResetRunning = false

    /// One `reach`, with all five arguments kept.
    ///
    /// **All five, because what the loop passes is half of what is worth testing.** The candidate PINs, the
    /// rotation target and both names are read from the table on every attempt rather than carried from
    /// launch -- that is the first rule in `CLAUDE.md` and `DeviceReconnector`'s own doc comment insists on
    /// it -- and a loop that reached with values captured once would look identical from outside unless a
    /// test could see the arguments.
    struct Reach: Equatable {
        let id: UUID
        let candidates: [String]
        let rotatingTo: String?
        let remembered: String?
        let previouslyKnown: String?
    }

    /// Every `reach` this radio was asked to make, in order.
    private(set) var reaches: [Reach] = []

    /// How many times the last scan's findings were dropped.
    private(set) var forgetCount = 0

    var lastReach: Reach? { reaches.last }

    func reach(
        _ id: UUID,
        presenting candidates: [String],
        rotatingTo: String?,
        remembered: String?,
        previouslyKnown: String?
    ) {
        reaches.append(
            Reach(
                id: id,
                candidates: candidates,
                rotatingTo: rotatingTo,
                remembered: remembered,
                previouslyKnown: previouslyKnown
            )
        )
    }

    func forgetWhatWasFound() { forgetCount += 1 }
}
