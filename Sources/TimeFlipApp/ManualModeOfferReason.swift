import Foundation

/// Why the app gave up on the device, in the terms the manual-mode offer's log line needs.
///
/// "Nothing was in range" and "it was right there and refused this app's PIN" are different
/// problems with different fixes, and this line is the only place they can be told apart. It has
/// been got wrong twice, both times because the caller was trusted to say which had happened:
/// once by a message that named an attempt count and nothing else, and once by a `reason` string
/// passed in at the call site, where the *accurate* caller lost a race to the inaccurate one and
/// the log confidently blamed a cube that was sitting on the desk (measured on hardware
/// 2026-08-09: 3ms between `none of the 1 eligible device(s) accepted this app's PIN` and an offer
/// reading `nothing eligible found in the scan`).
///
/// So the answer is derived from what the attempt actually counted rather than from who calls.
enum ManualModeOfferReason {

    /// - Parameters:
    ///   - eligibleFound: how many devices the scan listed as this app's to try.
    ///   - refusedPIN: how many of those answered and rejected the password.
    static func describe(eligibleFound: Int, refusedPIN: Int) -> String {
        guard eligibleFound > 0 else {
            return "nothing eligible found in the scan"
        }
        if refusedPIN >= eligibleFound {
            return eligibleFound == 1
                ? "the one device found refused this app's PIN"
                : "all \(eligibleFound) devices found refused this app's PIN"
        }
        // Found, and not a password problem: something was there and could not be reached. Worth
        // its own wording rather than being folded into either of the above, both of which would
        // send someone looking in the wrong place.
        let noun = eligibleFound == 1 ? "device" : "devices"
        return "\(eligibleFound) \(noun) found, none of them reachable"
    }
}
