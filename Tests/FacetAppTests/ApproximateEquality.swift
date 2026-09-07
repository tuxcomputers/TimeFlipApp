import Foundation

/// A tolerance comparison for the colour channels, standing in for XCTest's `accuracy:`.
///
/// **swift-testing has no `accuracy:` parameter**, `#expect` taking one expression rather than a pair.
/// The six call sites this replaces all compare an sRGB channel that came out of a hex string -- `128/255`
/// is not representable -- so the tolerance is the point of the assertion rather than a detail of it, and
/// naming it here keeps that visible instead of spelling `abs(a - b) < 0.001` six times.
extension Double {
    /// Whether this is `other`, give or take a thousandth. Chosen to match what the XCTest assertions
    /// this replaced were written with, so no test changed what it tolerates.
    func isApproximately(_ other: Double, within tolerance: Double = 0.001) -> Bool {
        abs(self - other) <= tolerance
    }
}
