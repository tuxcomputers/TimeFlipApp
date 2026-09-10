#if canImport(CDBus)
import Foundation
import Testing
@testable import FacetCore
@testable import FacetLinux

/// Covers `BlueZCubeRadio`: the reach, and what it does with what answers.
///
/// **The rule being pinned is the archive's, and it is the one that matters most in a room with two cubes.** A
/// reach asks "does this one take our PIN", never "is this the right identifier", so a refusal is an answer and the
/// queue moves on. The archive recorded what the other version cost: "a colleague's cube advertising a moment
/// sooner was enough to lock this user out of their own device".
///
/// **Nothing here is timed.** Every wait is a wake on `HandDrivenScheduler`, driven by the interval it was arranged
/// for, so a scan window is a call rather than fifteen real seconds.
@Suite @MainActor
final class BlueZCubeRadioTests {
    private let link = FakeBlueZLink()
    private let clock = HandDrivenScheduler()

    private lazy var radio = BlueZCubeRadio(link: link, scheduler: clock, debugLog: nil)

    private let ours = BlueZAddress.identifier(forAddress: "E8:DB:D8:CF:F9:0F")!
    private let theirs = BlueZAddress.identifier(forAddress: "AA:BB:CC:DD:EE:FF")!

    private var outcomes: [(id: UUID, outcome: DeviceLoginOutcome)] = []
    private var dropped: [UUID] = []
    private var linksEnded: [UUID] = []

    init() {
        radio.onLoginEnded = { [self] id, outcome in outcomes.append((id, outcome)) }
        radio.onConnectionDropped = { [self] id in dropped.append(id) }
        radio.onLinkEnded = { [self] id in linksEnded.append(id) }
    }

    private func reachForOurs(presenting candidates: [String] = ["123456"]) {
        radio.reach(
            ours,
            presenting: candidates,
            rotatingTo: nil,
            remembered: "TimeFlip v2.0",
            previouslyKnown: nil
        )
    }

    /// One turn of the scan poll.
    private func look() {
        clock.tickAll(after: BlueZCubeRadio.scanPollSeconds)
    }

    /// The scan window closing with whatever has been seen.
    private func closeTheWindow() {
        clock.tickAll(after: BlueZCubeRadio.scanSeconds)
    }

    /// One turn of the poll that waits for the services to resolve.
    private func lookForResolution() {
        clock.tickAll(after: BlueZCubeRadio.resolvePollSeconds)
    }

    /// Drives the login on the newest GATT table as far as the PIN verdict, and answers with that verdict's bytes.
    ///
    /// `0x02` is accepted and `0x01` is rejected, which is the reverse of what the vendor spec says: finding 4,
    /// measured on this cube with both outcomes three seconds apart.
    private func answerThePIN(accepted: Bool) throws {
        let gatt = try #require(link.gatts.last)
        gatt.answerServices([TimeFlipUUIDs.serviceString])
        gatt.answerCharacteristics(
            [TimeFlipUUIDs.passwordString, TimeFlipUUIDs.commandResultString, TimeFlipUUIDs.commandString],
            ofService: TimeFlipUUIDs.serviceString
        )
        gatt.acknowledge(TimeFlipUUIDs.passwordString)
        gatt.deliver(Data([accepted ? 0x02 : 0x01]), from: TimeFlipUUIDs.commandResultString)
    }

    // MARK: - looking

    @Test func testAReachPowersTheAdapterOnAndStartsLooking() {
        reachForOurs()

        #expect(link.poweredOn == 1)
        #expect(link.discoveriesStarted == 1)
        #expect(radio.isScanning)
        #expect(radio.isReachingForCube)
    }

    @Test func testAnAdapterThatWillNotPowerOnEndsTheReachRatherThanScanningAnyway() {
        link.powersOn = false

        reachForOurs()

        #expect(link.discoveriesStarted == 0)
        #expect(outcomes.map(\.outcome) == [.unreachable])
        #expect(!radio.isReachingForCube)
    }

    @Test func testASecondReachIsRefusedWhileOneIsRunning() {
        reachForOurs()
        reachForOurs()

        #expect(link.discoveriesStarted == 1, "the second is not a second scan")
    }

    @Test func testTheRememberedCubeTurningUpEndsTheWindowEarly() {
        reachForOurs()
        link.add(ours, named: "TimeFlip v2.0")

        look()

        #expect(!radio.isScanning, "the window ended on its own rather than at fifteen seconds")
        #expect(link.discoveriesStopped == 1)
        #expect(link.connects == [ours], "and the device it found is being tried")
    }

    @Test func testSomethingElseEligibleDoesNotEndTheWindowEarly() {
        // A room may hold a cube that answers a moment later and is the one this app paired with, so only the
        // remembered identifier is worth cutting the look short for.
        reachForOurs()
        link.add(theirs, named: "TimeFlip v2.0", address: "AA:BB:CC:DD:EE:FF")

        look()

        #expect(radio.isScanning)
        #expect(link.connects.isEmpty)
    }

    @Test func testAWindowThatFoundNothingIsUnreachableRatherThanAWrongPIN() {
        // The two have different things to tell the user, and `DeviceReconnector` says different things about them.
        reachForOurs()

        closeTheWindow()

        #expect(outcomes.map(\.outcome) == [.unreachable])
        #expect(!radio.isReachingForCube)
    }

    @Test func testWhatTheScanSawIsPublishedAndCanBeDropped() {
        var published: [[ScannedDevice]] = []
        radio.onDevicesChanged = { published.append($0) }
        reachForOurs()
        link.add(theirs, named: "Headphones", address: "AA:BB:CC:DD:EE:FF")

        look()
        #expect(published.last?.count == 1)

        radio.forgetWhatWasFound()
        #expect(published.last?.isEmpty == true)
    }

    // MARK: - trying what answered

    @Test func testTheRememberedIdentifierIsTriedFirst() {
        // A ranking of guesses rather than a filter: the identifier leads because it is the surest thing available
        // when it is right, and the answer is still the PIN.
        reachForOurs()
        link.add(theirs, named: "TimeFlip v2.0", address: "AA:BB:CC:DD:EE:FF")
        link.add(ours, named: "TimeFlip v2.0")

        closeTheWindow()

        #expect(link.connects.first == ours)
    }

    @Test func testTheLoginWaitsForTheServicesToResolve() throws {
        // Connected and resolved are different facts and the app needs the second: nothing can be looked up by UUID
        // until BlueZ has read the GATT tree, which is several round trips after the link is reported up.
        reachForOurs()
        link.add(ours, named: "TimeFlip v2.0")
        look()

        lookForResolution()
        #expect(link.gatts.isEmpty, "no login has begun on a device whose tree has not been read")

        link.resolve(ours)
        lookForResolution()
        #expect(link.gatts.count == 1)
    }

    @Test func testACubeThatNeverResolvesIsGivenUpOn() {
        reachForOurs()
        link.add(ours, named: "TimeFlip v2.0")
        look()

        clock.tickAll(after: BlueZCubeRadio.resolveSeconds)

        #expect(link.gatts.isEmpty)
        #expect(outcomes.map(\.outcome) == [.unreachable], "the reach reports once, not once per device")
        #expect(link.disconnects == [ours], "and the link it was holding is let go of")
    }

    @Test func testAConnectThatFailsMovesOnRatherThanEndingTheReach() {
        link.connectFailure = BlueZRadio.Failure.refused("le-connection-abort-by-local")
        reachForOurs()
        link.add(ours, named: "TimeFlip v2.0")

        closeTheWindow()

        #expect(outcomes.map(\.outcome) == [.unreachable])
    }

    // MARK: - the PIN is the answer

    @Test func testACubeThatTakesThePINIsTheConnectedDevice() throws {
        reachForOurs()
        link.add(ours, named: "TimeFlip v2.0")
        look()
        link.resolve(ours)
        lookForResolution()

        try answerThePIN(accepted: true)

        #expect(radio.connectedDevice == ours)
        #expect(outcomes.map(\.outcome) == [.loggedIn])
        #expect(!radio.isReachingForCube)
    }

    @Test func testARefusedPINIsFollowedByTheNextOneOnTheSameDevice() throws {
        // **A refusal is an answer, not a failure.** The next PIN on the same device comes before the next device,
        // because a cube whose batteries came out is on the vendor default and is still this app's cube.
        reachForOurs(presenting: ["123456", "000000"])
        link.add(ours, named: "TimeFlip v2.0")
        look()
        link.resolve(ours)
        lookForResolution()

        try answerThePIN(accepted: false)

        #expect(link.connects == [ours, ours], "the same device again, on a fresh link")
        #expect(link.disconnects == [ours], "and the refused link was let go of first")
        #expect(outcomes.isEmpty, "a refused PIN is not an outcome to report while there is another to present")
    }

    @Test func testADeviceThatRefusesEveryPINIsTheEndOfThatDevice() throws {
        reachForOurs(presenting: ["123456"])
        link.add(theirs, named: "TimeFlip v2.0", address: "AA:BB:CC:DD:EE:FF")
        link.add(ours, named: "TimeFlip v2.0")
        closeTheWindow()
        link.resolve(ours)
        lookForResolution()

        try answerThePIN(accepted: false)

        // Not reported, either: telling the reconnect loop about one refusal would have it offer manual mode on
        // the first colleague's cube that answered.
        #expect(outcomes.isEmpty)
        #expect(link.connects == [ours, theirs], "the queue moves on to the other one")
    }

    @Test func testEverythingRefusingIsAWrongPINRatherThanUnreachable() throws {
        reachForOurs(presenting: ["123456"])
        link.add(ours, named: "TimeFlip v2.0")
        closeTheWindow()
        link.resolve(ours)
        lookForResolution()

        try answerThePIN(accepted: false)

        #expect(
            outcomes.map(\.outcome) == [.wrongPIN],
            "reported once, by the reach ending having had something refuse it"
        )
    }

    @Test func testSomethingThatIsNotACubeIsNotAWrongPIN() throws {
        // A device with no TimeFlip service on it answered the scan on its name. Reporting that as a wrong PIN
        // would send somebody hunting a PIN problem they do not have.
        reachForOurs()
        link.add(ours, named: "TimeFlip v2.0")
        closeTheWindow()
        link.resolve(ours)
        lookForResolution()
        let gatt = try #require(link.gatts.last)

        gatt.answerServices(["180F"])

        #expect(
            outcomes.map(\.outcome) == [.unreachable],
            "nothing refused a PIN, so what ended is a reach that found no cube rather than one that was refused"
        )
    }

    // MARK: - the link, once there is one

    @Test func testALinkThatGoesIsReportedOnce() throws {
        reachForOurs()
        link.add(ours, named: "TimeFlip v2.0")
        look()
        link.resolve(ours)
        lookForResolution()
        try answerThePIN(accepted: true)

        link.drop(ours)
        clock.tickAll(after: BlueZCubeRadio.linkPollSeconds)

        #expect(radio.connectedDevice == nil)
        #expect(dropped == [ours])
        #expect(linksEnded == [ours], "so whatever holds per-link state lets go of it")
    }

    @Test func testALinkThatIsStillUpIsNotReportedAsGone() throws {
        reachForOurs()
        link.add(ours, named: "TimeFlip v2.0")
        look()
        link.resolve(ours)
        lookForResolution()
        try answerThePIN(accepted: true)

        clock.tickAll(after: BlueZCubeRadio.linkPollSeconds)

        #expect(radio.connectedDevice == ours)
        #expect(dropped.isEmpty)
    }

    @Test func testATreeThatCannotBeReadIsNotACubeLeavingTheRoom() throws {
        // A bus problem and a cube going away look the same from here unless the difference is kept: reporting a
        // drop for the first would have the reconnect loop chasing a cube that never went anywhere.
        reachForOurs()
        link.add(ours, named: "TimeFlip v2.0")
        look()
        link.resolve(ours)
        lookForResolution()
        try answerThePIN(accepted: true)

        link.records.removeAll()
        clock.tickAll(after: BlueZCubeRadio.linkPollSeconds)

        #expect(radio.connectedDevice == ours)
        #expect(dropped.isEmpty)
    }

    // MARK: - asking with nothing there

    @Test func testACommandWithNoCubeIsAnsweredRatherThanDropped() {
        // A caller waiting on a completion that never comes is the failure mode that hangs a quit.
        var answered: Bool?
        radio.send(DeviceCommandRules.pause(true)) { answered = $0 }

        #expect(answered == false)
    }

    @Test func testAHistoryFetchWithNoCubeAnswersNothing() {
        var answered: [DeviceEventSegment]?
        radio.fetchHistory(from: 0) { answered = $0 }

        #expect(answered?.isEmpty == true)
    }
}
#endif
