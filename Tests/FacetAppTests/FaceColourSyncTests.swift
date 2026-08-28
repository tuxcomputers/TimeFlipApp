@testable import FacetApp
import AppKit
import XCTest

/// Covers telling the cube what to light each face in: what goes out, in what order, and what does not go out at all.
///
/// **The sequencing is the part worth pinning and it is not tidiness.** `DeviceLogin.send` refuses a command while one
/// is still out, so twelve faces sent at once would be one write and eleven refusals -- and nothing on the device side
/// would say so, `0x11` having no read-back of any kind. A test that only checked the bytes would pass on an
/// implementation that lights one face.
@MainActor
final class FaceColourSyncTests: XCTestCase {
    /// What the pretend cube was told, in order.
    private final class Wire {
        var sent: [Data] = []
        /// Completions not yet answered, for the tests that need a command to still be out.
        var waiting: [(Bool) -> Void] = []
        var faces: [Int] { sent.compactMap { $0.count >= 2 ? Int($0[1]) : nil } }
    }

    /// - Parameters:
    ///   - answering: whether the cube replies at all. `false` holds every completion open, which is how a command
    ///     still being out is modelled.
    ///   - colours: what each face should be lit in, read through the closure so a test can change it mid-run.
    /// Whether a cube is connected, as something a test can change: the opening send is gated on this going true,
    /// so a fixed value cannot express the case that matters.
    private final class Link {
        var isCubeConnected = true
    }

    private func sync(
        connected: Bool = true,
        link: Link? = nil,
        answering: Bool = true,
        takes: Bool = true,
        colours: @escaping (Int) -> NSColor? = { _ in NSColor(hex: "#ff0000") },
        on wire: Wire
    ) -> FaceColourSync {
        let link = link ?? Link()
        link.isCubeConnected = connected
        return FaceColourSync(
            send: { command, reported in
                wire.sent.append(command)
                if answering {
                    reported(takes)
                } else {
                    wire.waiting.append(reported)
                }
            },
            isCubeConnected: { link.isCubeConnected },
            faceColour: { face in FaceColour(face: face, categoryName: nil, colour: colours(face)) },
            debugLog: nil
        )
    }

    // MARK: - a link coming up

    func testALinkComingUpSendsEveryFaceInOrder() {
        let wire = Wire()

        sync(on: wire).sendAll(because: "a test")

        XCTAssertEqual(wire.faces, Array(1...12))
    }

    func testTheNextFaceWaitsForTheOneBeforeIt() {
        // The whole reason this is a queue rather than a loop. With the first command still out, nothing else may be
        // written: `DeviceLogin.send` would refuse it, and a refusal for a command with no read-back is invisible.
        let wire = Wire()
        // Held in a local rather than sent to directly: the completion holds the sync weakly, so a temporary one is
        // gone before the cube answers and the run stops after its first face.
        let colours = sync(answering: false, on: wire)
        colours.sendAll(because: "a test")

        XCTAssertEqual(wire.faces, [1], "one command out, eleven still queued")

        wire.waiting.removeFirst()(true)

        XCTAssertEqual(wire.faces, [1, 2], "and the second only once the first came back")
    }

    func testACubeThatRefusesOneFaceIsStillToldAboutTheRest() {
        // A refusal is not the end of the run. Eleven faces showing the right colour beats stopping at the first one
        // the cube would not take, and there is no read-back to make the refusal mean more than it does.
        let wire = Wire()

        sync(takes: false, on: wire).sendAll(because: "a test")

        XCTAssertEqual(wire.faces, Array(1...12))
    }

    // MARK: - an edit

    func testAnEditSendsOneFaceAndNotTwelve() {
        let wire = Wire()

        sync(on: wire).send(face: 4, because: "a test")

        XCTAssertEqual(wire.faces, [4])
    }

    func testAFaceNoCubeHasIsNotSent() {
        // Manual mode's faces, which exist precisely because no cube does. Both paths that assign a category reach
        // this, so it is the ordinary case rather than an edge of one.
        let wire = Wire()

        sync(on: wire).send(face: ManualFace.all[0], because: "a test")

        XCTAssertEqual(wire.sent, [])
    }

    func testNothingIsSentWithNoCubeConnected() {
        // Nothing is queued for later either: the next link coming up sends all twelve anyway, so there is nothing
        // for a deferral to be worth.
        let wire = Wire()

        sync(connected: false, on: wire).sendAll(because: "a test")

        XCTAssertEqual(wire.sent, [])
    }

    func testAnEditArrivingMidRunGoesOutBehindIt() {
        // Not dropped, and not written over the top of a command already out. Face 1 is the one in flight when the
        // edit arrives, so this is also the case below: a face already sent is queued again rather than deduped.
        let wire = Wire()
        let colours = sync(answering: false, on: wire)
        colours.sendAll(because: "a test")

        colours.send(face: 1, because: "an edit")

        XCTAssertEqual(wire.faces, [1], "still just the one that was already out")

        while !wire.waiting.isEmpty { wire.waiting.removeFirst()(true) }

        XCTAssertEqual(wire.faces, Array(1...12) + [1], "and the edit lands after the run it arrived during")
    }

    func testAFaceAlreadyWaitingIsNotQueuedTwice() {
        // A second entry for a face still waiting would send the same colour again, the colour being read when the
        // command is built. That is a flash write and an LED flash for nothing, which is the cost the archive
        // measured. Face 4 is the one in flight here, so 5 is the one that gets asked for twice.
        let wire = Wire()
        let colours = sync(answering: false, on: wire)
        colours.send(face: 4, because: "a test")

        colours.send(face: 5, because: "an edit")
        colours.send(face: 5, because: "the same face again")
        while !wire.waiting.isEmpty { wire.waiting.removeFirst()(true) }

        XCTAssertEqual(wire.faces, [4, 5])
    }

    func testAFaceRecolouredWhileItsOwnCommandIsOutIsSentAgain() {
        // **The in-flight face is deliberately not deduped**, and this is why: the command already on the wire is
        // carrying the colour from before the edit, so treating the new one as a duplicate would leave the cube
        // showing what the user has just changed away from. The last edit has to win.
        let wire = Wire()
        let colours = sync(answering: false, on: wire)
        colours.send(face: 4, because: "a test")

        colours.send(face: 4, because: "recoloured while that was out")
        while !wire.waiting.isEmpty { wire.waiting.removeFirst()(true) }

        XCTAssertEqual(wire.faces, [4, 4])
    }

    func testTheColourIsReadWhenTheCommandIsBuiltAndNotWhenItWasQueued() {
        // `CLAUDE.md`'s first rule, read literally. A face queued behind eleven others whose category has changed in
        // the meantime goes out as what it is now, not as what it was when the run started.
        let wire = Wire()
        var hex = "#ff0000"
        let colours = sync(answering: false, colours: { _ in NSColor(hex: hex) }, on: wire)
        colours.sendAll(because: "a test")

        hex = "#0000ff"
        while !wire.waiting.isEmpty { wire.waiting.removeFirst()(true) }

        XCTAssertEqual(wire.sent.first, Data([0x11, 1, 0xFF, 0xFF, 0, 0, 0, 0]), "the one already out was red")
        XCTAssertEqual(wire.sent.last, Data([0x11, 12, 0, 0, 0, 0, 0xFF, 0xFF]), "and the last one read blue")
    }

    // MARK: - the cube asking

    func testACubeBecomingConnectedSendsAllTwelve() {
        let wire = Wire()

        sync(on: wire).linkSettled()

        XCTAssertEqual(wire.faces, Array(1...12))
    }

    func testSettlingTwiceOnOneConnectionSendsOnce() {
        // **The transition is what is gated on, not the state.** A cube still connected from the last send has been
        // coloured already, so a callback that fires twice must not cost twelve more flash writes.
        let wire = Wire()
        let colours = sync(on: wire)
        colours.linkSettled()

        colours.linkSettled()

        XCTAssertEqual(wire.faces, Array(1...12))
    }

    func testSettlingOnACubeNoLongerConnectedSendsNothing() {
        // The callback says the login finished; it says nothing about whether that cube is still there.
        let wire = Wire()
        let link = Link()
        let colours = sync(link: link, on: wire)
        link.isCubeConnected = false

        colours.linkSettled()

        XCTAssertEqual(wire.sent, [])
    }

    func testEachNewConnectionIsItsOwnChangeToTrue() {
        let wire = Wire()
        let link = Link()
        let colours = sync(link: link, on: wire)
        colours.linkSettled()

        link.isCubeConnected = false
        colours.linkEnded()
        link.isCubeConnected = true
        colours.linkSettled()

        XCTAssertEqual(wire.faces.count, 24, "twelve for each connection")
    }

    func testTheCubeAskingIsAnswered() {
        let wire = Wire()
        let colours = sync(on: wire)
        colours.linkSettled()

        colours.cubeAskedForThem()

        XCTAssertEqual(wire.faces, Array(1...12) + Array(1...12), "the link, then the asking")
    }

    func testTheCubeAskingBeforeTheLinkSettlesIsAnsweredByTheLinkSettling() {
        // **The measured case, and the only one this cube has ever produced.** The systemState read is answered
        // `02 02 00 00` about 480ms before the login's last question comes back, with a `0x17` read still outstanding
        // that does not set `isCommandInFlight` -- so sending here would write over the login rather than be refused.
        // All twelve are a moment away regardless, so the request is answered by them and not by a run of its own.
        let wire = Wire()
        let colours = sync(on: wire)

        colours.cubeAskedForThem()

        XCTAssertEqual(wire.sent, [], "nothing on the wire while the login is still talking")

        colours.linkSettled()

        XCTAssertEqual(wire.faces, Array(1...12), "twelve, not twenty-four")
    }

    func testTheCubeAskingAgainInsideTheCooldownIsNotAnswered() {
        // The archive's measurement: a cube that has lost its colours asks on every notification, every re-read and
        // every reconnect, and 8 requests in one second became 96 colour writes that helped brown out a failing
        // device. One answer, then the asking is counted rather than obeyed.
        let wire = Wire()
        let colours = sync(on: wire)
        colours.linkSettled()
        colours.cubeAskedForThem()

        colours.cubeAskedForThem()
        colours.cubeAskedForThem()

        XCTAssertEqual(wire.faces, Array(1...12) + Array(1...12), "twenty-four, not forty-eight")
    }

    func testAnEditIsNotSilencedByTheCooldown() {
        // The cooldown is aimed at the cube repeating itself, not at the app. Somebody recolouring a category while
        // one is running has changed what a face should show, and that is a different question.
        let wire = Wire()
        let colours = sync(on: wire)
        colours.linkSettled()
        colours.cubeAskedForThem()

        colours.send(face: 4, because: "an edit")

        XCTAssertEqual(wire.faces.last, 4)
    }

    // MARK: - the link going

    func testWhatIsStillQueuedIsDroppedWhenTheLinkGoes() {
        // Sending the rest one refusal at a time would be a dozen rows saying the cube is gone where one says it once.
        let wire = Wire()
        let colours = sync(answering: false, on: wire)
        colours.sendAll(because: "a test")

        colours.linkEnded()
        wire.waiting.removeFirst()(false)

        XCTAssertEqual(wire.faces, [1], "the one that was already out, and nothing behind it")
    }

    func testANewLinkGetsAFreshHearing() {
        // The cooldown stops one connection's repeated asking from being re-answered. A cube that comes back having
        // really lost its colours is a different cube-worth of asking.
        let wire = Wire()
        let link = Link()
        let colours = sync(link: link, on: wire)
        colours.linkSettled()
        colours.cubeAskedForThem()

        link.isCubeConnected = false
        colours.linkEnded()
        link.isCubeConnected = true
        colours.linkSettled()
        colours.cubeAskedForThem()

        XCTAssertEqual(wire.faces.count, 48, "two connections and an answered ask on each")
    }

    func testAskingIsNotCarriedOverALinkThatWent() {
        // A request made on a connection that then dropped is answered by the next connection sending all twelve, not
        // by an extra run on top of it. What the cube wanted was its colours, and it is about to get them.
        let wire = Wire()
        let colours = sync(on: wire)
        colours.cubeAskedForThem()

        colours.linkEnded()
        colours.linkSettled()

        XCTAssertEqual(wire.faces, Array(1...12), "the next connection sends them, and no extra run on top")
    }
}
