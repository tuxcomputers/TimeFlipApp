@testable import FacetApp
import XCTest

/// Covers when the status item stops saying `Connecting…`.
///
/// Worth testing because the answer is a latch over three separate facts, and every one of them is cleared again by a
/// dropped link -- so the difference between "has not read the cube yet" and "read it and then lost it" exists only
/// here, and the two draw completely different lines.
final class CubeFirstReadingTests: XCTestCase {
    /// A cube that has answered everything.
    private func complete(_ reading: inout CubeFirstReading) {
        reading.record(isCubeConnected: true, cubeFace: 4, cubePauseState: .running, cubeLockState: .unlocked)
    }

    func testAPairedLaunchIsConnectingUntilItHasReadTheCube() {
        var reading = CubeFirstReading()
        XCTAssertFalse(reading.hasReadTheCube)
        XCTAssertTrue(reading.isConnecting(isManualMode: false))

        complete(&reading)
        XCTAssertTrue(reading.hasReadTheCube)
        XCTAssertFalse(reading.isConnecting(isManualMode: false))
    }

    func testEveryOneOfTheThreeFactsIsWaitedFor() {
        // A connection is not a reading: `DeviceLogin` reports `.loggedIn` when the PIN is accepted, several round
        // trips before the `0x10` read the lock and the pause come from. Each of these is that window.
        var noFace = CubeFirstReading()
        noFace.record(isCubeConnected: true, cubeFace: nil, cubePauseState: .running, cubeLockState: .unlocked)
        XCTAssertFalse(noFace.hasReadTheCube, "no face yet")

        var noPause = CubeFirstReading()
        noPause.record(isCubeConnected: true, cubeFace: 4, cubePauseState: .unknown, cubeLockState: .unlocked)
        XCTAssertFalse(noPause.hasReadTheCube, "the cube has not said whether it is running")

        var noLock = CubeFirstReading()
        noLock.record(isCubeConnected: true, cubeFace: 4, cubePauseState: .running, cubeLockState: .unknown)
        XCTAssertFalse(noLock.hasReadTheCube, "the cube has not said whether it is locked")

        var notConnected = CubeFirstReading()
        notConnected.record(isCubeConnected: false, cubeFace: 4, cubePauseState: .running, cubeLockState: .unlocked)
        XCTAssertFalse(notConnected.hasReadTheCube, "a face out of device_event is last session's, not a reading")
    }

    func testADropAfterAReadingDoesNotPutConnectingBack() {
        // The case that decides the shape of this type. A drop clears the face, the lock and the pause at the radio,
        // so without the latch every drop would read as a launch that had never found its cube -- and the line is
        // meant to keep the category and turn yellow.
        var reading = CubeFirstReading()
        complete(&reading)

        reading.record(isCubeConnected: false, cubeFace: nil, cubePauseState: .unknown, cubeLockState: .unknown)
        XCTAssertTrue(reading.hasReadTheCube, "one-way: nothing sets it back")
        XCTAssertFalse(reading.isConnecting(isManualMode: false))
    }

    func testTimingByHandIsNeverConnecting() {
        // Both ends of it. A launch with nothing paired has no cube to reach for, and one that answered the
        // cube-not-found offer with Time by Hand has stopped reaching -- `isManualMode` is that same fact, so the
        // title ends on it without this type being told separately.
        var neverRead = CubeFirstReading()
        XCTAssertFalse(neverRead.isConnecting(isManualMode: true))

        complete(&neverRead)
        XCTAssertFalse(neverRead.isConnecting(isManualMode: true))
    }

    func testRescanningLeavesTheTitleSaying() {
        // Rescan settles nothing: the launch is still paired and still looking, so `isManualMode` stays false and
        // the line goes on saying what is still true. Only Time by Hand ends it.
        let reading = CubeFirstReading()
        XCTAssertTrue(reading.isConnecting(isManualMode: false), "before the offer")
        XCTAssertTrue(reading.isConnecting(isManualMode: false), "and after choosing Rescan, which changes neither input")
    }
}
