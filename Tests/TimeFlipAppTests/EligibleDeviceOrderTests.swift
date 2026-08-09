@testable import TimeFlipApp
import XCTest

/// The order a startup scan tries candidates in.
///
/// This exists because of what it replaced. The upstream driver connected to whichever TimeFlip
/// answered the scan first and stopped there, so in an office with several cubes it would grab a
/// colleague's, be refused at login because their PIN is not this app's, and give up without ever
/// trying the user's own device sitting on the same desk. The stored `device_uuid` could have
/// settled it and the connect path never read it.
final class EligibleDeviceOrderTests: XCTestCase {
    private let mine = UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000001")!
    private let theirs = UUID(uuidString: "BBBBBBBB-0000-0000-0000-000000000002")!
    private let spare = UUID(uuidString: "CCCCCCCC-0000-0000-0000-000000000003")!

    func testThePairedDeviceIsTriedFirstHoweverItSorts() {
        // "Zoe's cube" sorts last and is still tried first, because the uuid is the surest
        // identification available and putting it first costs the usual case one login attempt.
        let found = [
            EligibleDevice(id: theirs, name: "Alex's cube"),
            EligibleDevice(id: spare, name: "Spare cube"),
            EligibleDevice(id: mine, name: "Zoe's cube")
        ]

        let ordered = EligibleDevice.ordered(found, preferring: mine)

        XCTAssertEqual(ordered.map(\.name), ["Zoe's cube", "Alex's cube", "Spare cube"])
    }

    func testEveryOtherDeviceIsStillTried() {
        // The bug this fixes is giving up early, so preferring one must never drop the others: a
        // cube re-paired, reset, or first paired on another Mac no longer carries this uuid and is
        // still the user's own device.
        let found = [
            EligibleDevice(id: theirs, name: "Alex's cube"),
            EligibleDevice(id: spare, name: "Spare cube")
        ]

        let ordered = EligibleDevice.ordered(found, preferring: mine)

        XCTAssertEqual(
            ordered.count, 2,
            "the paired uuid orders the list, it does not filter it -- nothing may be dropped"
        )
    }

    func testWithNoPairedUUIDTheOrderIsStillStable() {
        // A never-paired app has no uuid to prefer, and two scans of the same room must still try
        // the same devices in the same order rather than whatever the dictionary felt like.
        let found = [
            EligibleDevice(id: spare, name: "Spare cube"),
            EligibleDevice(id: theirs, name: "Alex's cube")
        ]

        XCTAssertEqual(
            EligibleDevice.ordered(found, preferring: nil).map(\.name),
            ["Alex's cube", "Spare cube"]
        )
    }

    func testAPairedUUIDThatIsNotInRangeChangesNothing() {
        let found = [
            EligibleDevice(id: theirs, name: "Alex's cube"),
            EligibleDevice(id: spare, name: "Spare cube")
        ]

        XCTAssertEqual(
            EligibleDevice.ordered(found, preferring: mine).map(\.name),
            ["Alex's cube", "Spare cube"]
        )
    }

    func testAnEmptyScanOrdersToNothing() {
        XCTAssertTrue(EligibleDevice.ordered([], preferring: mine).isEmpty)
    }
}
