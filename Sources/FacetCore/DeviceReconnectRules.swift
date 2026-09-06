import Foundation

/// When a paired app should reach for its cube, and how long to wait before trying again.
///
/// **Every decision here is a value in and an answer out**, which is the same split `DeviceLoginRules` and
/// `DevicePairingRules` are: the part worth testing must not be the part that needs a cube on the desk. `swift test`
/// cannot scan, so the loop that drives this is verified on hardware and only the judgements are covered here -- which
/// is why the judgements are all in this file rather than inline in the loop.
///
/// **Massaged from `ApplicationDelegate.scheduleReconnect` / `handleReconnectFailure`.** The policy is the archive's and
/// it survives inspection: retry for as long as the app is paired, back off so a cube that is not coming back is not
/// hammered, cap the backoff so one that does come back is picked up promptly, and never let a failure touch the
/// pairing. What is not kept is where it lived -- two methods and a mutable counter spread through a 1,762-line
/// delegate, tangled together with a manual-mode offer this app has not rebuilt.
enum DeviceReconnectRules {
    /// Whether an attempt may start right now.
    ///
    /// **`isCubePaired` is the only reason to try at all**, and it is read from the table at the moment this is asked rather
    /// than remembered from launch: pairing and forgetting both happen while the app runs, and a loop working from a
    /// copy would either chase a device the user has given up or sit still beside one they just paired.
    ///
    /// The middle three are "is the radio already busy". All of those states end in a callback that comes back here, so
    /// standing down is never giving up: a scan somebody started to look at the list finishes and this is asked again, a
    /// login in flight reports its own outcome, and a reset that is being confirmed is a cube deliberately being let go
    /// of. Starting a second attempt over the top of any of them would be two conversations with one radio.
    ///
    /// **The last one is the app having deliberately stopped**: it is the archive's `shouldAttemptConnection` minus its
    /// `shouldMaintainConnection` (which is `isCubePaired` here). No attempt from any path while the question is on
    /// screen -- somebody who starts the app and walks away has to find the offer exactly where they left it, not a
    /// backoff retry having quietly started another run of attempts behind the dialog.
    ///
    /// **`hasGivenUpOnCube` is the other one.** It is not the same parameter as "this app has no device", which is
    /// what it was once spelled as (`isManualMode`): a cube that cannot be found is still on record, and being
    /// unpaired is the first guard's business. What it *is* is the launch having been told to get on without the
    /// cube, which stops this loop and makes the app its own clock at the same time -- one flag, because they are one
    /// decision (`CubeNotFoundAnswer.timeByHand`).
    ///
    /// Both default to `false`, which reads as "no offer is up and nobody has said to stop" -- the state every caller
    /// that predates them was in.
    static func shouldAttempt(
        isCubePaired: Bool,
        isCubeConnected: Bool,
        isScanning: Bool,
        isReachingForCube: Bool,
        isFactoryResetRunning: Bool,
        isAwaitingAnswer: Bool = false,
        hasGivenUpOnCube: Bool = false
    ) -> Bool {
        guard isCubePaired, !isAwaitingAnswer, !hasGivenUpOnCube else { return false }
        return !isCubeConnected && !isScanning && !isReachingForCube && !isFactoryResetRunning
    }

    /// How long to wait before the attempt after `failures` failed ones. `2s, 4s, 6s ... 30s`.
    ///
    /// **The archive's, copied**, including the cap. What makes it right is what the two ends are for: the first retry
    /// is quick because much the commonest failure is a cube that was asleep and has just been flipped, and the cap
    /// exists because the commonest *long* failure is a cube in another building -- where the honest answer is to keep
    /// asking cheaply for hours rather than to give up or to spin.
    ///
    /// **Linear rather than doubling**, which is also the archive's and is the part worth being explicit about: a
    /// doubling backoff reaches half an hour in six steps, and a cube that comes back after ten minutes would then sit
    /// there unnoticed for another fifteen. The cost of asking is one ten-second scan.
    static func delay(afterFailures failures: Int) -> TimeInterval {
        TimeInterval(min(2 * (max(failures, 0) + 1), 30))
    }

    /// The cube to reach, out of `device_uuid.uuid`.
    ///
    /// **A row that does not parse is not a device**, and answering `nil` is what stops the loop scanning for ever for
    /// something it could never connect to: `paired` and `device_uuid` are written together, so the pair disagreeing is
    /// a database somebody has edited or a write that half landed. Either way there is nothing to reach.
    static func target(from uuid: String?) -> UUID? {
        guard let uuid, !uuid.isEmpty else { return nil }
        return UUID(uuidString: uuid)
    }
}
