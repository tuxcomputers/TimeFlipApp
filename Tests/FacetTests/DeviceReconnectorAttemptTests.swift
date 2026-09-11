@testable import FacetCore
import Foundation
import Testing

/// Covers the attempt itself: when the loop reaches for a cube, and what it hands the radio when it does.
///
/// **This is the half `DeviceReconnectorOfferTests` cannot reach.** That suite leaves `device_uuid` empty, so every
/// attempt stops at `DeviceReconnectRules.target` before the radio is touched -- which is how it stayed hermetic
/// against a real `BluetoothRadio`, and why `attempt()` and `scheduleAttempt()` had no test at all until 2026-09-09
/// (`docs/architecture-review-2026-09.md`, candidate 2). With `InMemoryCubeRadio` there is a radio to hand it to and
/// a record of what it was handed.
///
/// **What is mostly being asserted here is the first rule in `CLAUDE.md`**, and this module's doc comment is emphatic
/// about it: every value in a reach comes out of the table at the moment of the attempt, so forgetting a device stops
/// the loop, pairing another redirects it and a rename lands on the next try, with nothing carried from launch. That
/// is a claim about *when* a value is read, and a loop reading stale ones looks identical from outside unless a test
/// can see the arguments twice.
///
/// The timeout is driven by calling `attempt()`, which is what `scheduleAttempt`'s `Timer` does and all it does.
@Suite @MainActor
final class DeviceReconnectorAttemptTests {
    private let clock = HandDrivenScheduler()
    private let database: TemporaryDatabase
    private var settings: SettingStore!
    private var debugLog: DebugLog!
    private let radio = InMemoryCubeRadio()

    /// The cube these tests are paired to. Any valid UUID does; what matters is that it parses.
    private let cube = DeviceHandle("0BE1F1CE-0000-4000-8000-000000000001")

    init() throws {
        database = TemporaryDatabase()
        try database.bootstrap()
        try database.bootstrapDebug()
        settings = SettingStore(connection: database.connection())
        debugLog = DebugLog(databaseURL: database.debugURL, isRecording: true)
    }

    deinit {
        // Not isolated, so it cannot reach the loop; `database` is a `let` for that reason. Nothing needs stopping:
        // `attempt()` invalidates the pending timer on its way in, so a test that drives the timeout also clears it.
        database.remove()
    }

    private func logged(_ pattern: String) -> Bool {
        (Int(database.debugString("SELECT COUNT(*) FROM debug_log WHERE message LIKE '\(pattern)';") ?? "0") ?? 0) > 0
    }

    @discardableResult
    private func write(_ name: String, _ json: String) -> Bool {
        database.execute("UPDATE setting SET setting_value = '\(json)' WHERE setting_name = '\(name)';")
    }

    /// A paired app that knows which cube it has, which is the state every attempt below starts from.
    private func pair(to id: DeviceHandle? = nil, name: String = "Dibby", previously: String = "timeflip") {
        #expect(write("paired", "{\"paired\":true}"))
        #expect(write("device_uuid", "{\"uuid\":\"\((id ?? cube).value)\"}"))
        #expect(write("device_name", "{\"name\":\"\(name)\",\"previous_name\":\"\(previously)\"}"))
    }

    private func reconnector(
        storedPINs: @escaping () -> [String] = { [] },
        rotatingTo: @escaping () -> String? = { nil }
    ) -> DeviceReconnector {
        DeviceReconnector(
            radio: radio,
            settings: settings,
            debugLog: debugLog,
            scheduler: clock,
            storedPINs: storedPINs,
            rotatingTo: rotatingTo
        )
    }

    // MARK: - reaching at all

    @Test func testAPairedLaunchReachesForTheCubeTheTableNames() {
        pair()

        reconnector().follow()

        #expect(radio.reaches.count == 1, "a paired launch with a device should reach for it exactly once")
        #expect(radio.lastReach?.id == cube, "and for the device `device_uuid` names")
        #expect(logged("Paired, so going to look for the cube"))
    }

    @Test func testAnUnpairedLaunchReachesForNothing() {
        // `paired` is seeded false, so this is the never-paired state rather than one arranged here.
        reconnector().follow()

        #expect(radio.reaches.isEmpty)
        #expect(logged("Nothing paired, so there is no cube to follow"))
    }

    @Test func testAPairedLaunchWithNoDeviceNamedReachesForNothing() {
        // Paired, but `device_uuid` still `{}` -- the state a forget leaves behind.
        #expect(write("paired", "{\"paired\":true}"))

        reconnector().follow()

        #expect(radio.reaches.isEmpty)
        #expect(logged("Paired, but %device_uuid% names no device%"))
    }

    // MARK: - what the reach carries, and when it was read

    @Test func testTheNamesAreReadFromTheTableOnEveryAttempt() {
        // The rename case. Both names go into the radio's filter, and the point of reading them per attempt is that a
        // rename lands on the next try rather than at the next launch.
        pair(name: "Dibby", previously: "timeflip")
        let loop = reconnector()

        loop.attempt()
        #expect(radio.lastReach?.remembered == "Dibby")
        #expect(radio.lastReach?.previouslyKnown == "timeflip")

        #expect(write("device_name", "{\"name\":\"Renamed\",\"previous_name\":\"Dibby\"}"))
        loop.attempt()

        #expect(radio.lastReach?.remembered == "Renamed", "the second attempt should carry what the table says now")
        #expect(radio.lastReach?.previouslyKnown == "Dibby")
    }

    @Test func testTheDeviceIsReadFromTheTableOnEveryAttempt() {
        // Pairing a different cube redirects the loop, with nothing having to tell it.
        let other = DeviceHandle("0BE1F1CE-0000-4000-8000-000000000002")
        pair()
        let loop = reconnector()

        loop.attempt()
        #expect(radio.lastReach?.id == cube)

        #expect(write("device_uuid", "{\"uuid\":\"\(other.value)\"}"))
        loop.attempt()

        #expect(radio.lastReach?.id == other, "the attempt should follow the table rather than what it reached before")
    }

    @Test func testForgettingTheDeviceStopsTheLoopWithoutBeingTold() {
        pair()
        let loop = reconnector()
        loop.attempt()
        #expect(radio.reaches.count == 1)

        #expect(write("paired", "{\"paired\":false}"))
        loop.attempt()

        #expect(radio.reaches.count == 1, "an attempt after a forget should reach for nothing")
    }

    @Test func testTheRotationTargetIsAskedPerAttemptRatherThanCaptured() {
        // **The reason `rotatingTo` is a closure**, spelled out in its own doc comment: a release build picks six
        // random digits each time, so a target captured once would put the same PIN on every cube this launch met.
        // Nothing tested that until now, and a captured value passes every other test in this file.
        pair()
        var handedOut: [String] = []
        var next = 100_000
        let loop = reconnector(rotatingTo: {
            next += 1
            let pin = String(next)
            handedOut.append(pin)
            return pin
        })

        loop.attempt()
        loop.attempt()

        #expect(handedOut.count == 2, "the target should be asked for once per attempt")
        #expect(radio.reaches.map(\.rotatingTo) == handedOut.map { Optional($0) })
        #expect(radio.reaches[0].rotatingTo != radio.reaches[1].rotatingTo, "and a fresh one each time")
    }

    @Test func testTheCandidatePINsAreTheStoreReadThroughTheRules() {
        pair()
        var stored = ["111111"]
        let loop = reconnector(storedPINs: { stored })

        loop.attempt()
        #expect(radio.lastReach?.candidates == DeviceLoginRules.reconnectCandidates(stored: ["111111"]))
        #expect(radio.lastReach?.candidates.contains(DeviceLoginRules.defaultPIN) == true,
                "the vendor default is always presentable, which is what lets a reset cube be found")

        stored = ["222222"]
        loop.attempt()

        #expect(radio.lastReach?.candidates == DeviceLoginRules.reconnectCandidates(stored: ["222222"]),
                "the PINs are asked for per attempt, since the Keychain and the file can both change under it")
    }

    // MARK: - standing down while the radio is busy

    @Test func testACubeAlreadyConnectedIsNotReachedFor() {
        pair()
        radio.connectedDevice = cube

        reconnector().follow()

        #expect(radio.reaches.isEmpty)
        #expect(logged("Not reaching for the cube: the radio is busy with something else"))
    }

    @Test func testEachKindOfBusyRadioStandsTheAttemptDown() {
        // Four flags, and `DeviceReconnectRules.shouldAttempt` reads all four. The rules have their own tests; what
        // this asserts is that the loop hands it the radio's answers rather than something it remembered.
        pair()
        let loop = reconnector()

        radio.isScanning = true
        loop.attempt()
        radio.isScanning = false

        radio.isReachingForCube = true
        loop.attempt()
        radio.isReachingForCube = false

        radio.isFactoryResetRunning = true
        loop.attempt()
        radio.isFactoryResetRunning = false

        #expect(radio.reaches.isEmpty, "a busy radio should not be asked to reach, whichever way it is busy")

        loop.attempt()
        #expect(radio.reaches.count == 1, "and it should be asked once it is free")
    }

    // MARK: - arranging the next one

    @Test func testADropArrangesAnotherAttemptAndTheAttemptReaches() {
        // `scheduleAttempt` is what a drop reaches, and its `Timer` is what calls `attempt`. Driving `attempt`
        // directly is that timer's whole job.
        pair()
        let loop = reconnector()

        loop.noteDropped()

        #expect(radio.reaches.isEmpty, "nothing is reached for until the delay is up")
        #expect(logged("The cube went away%"))
        #expect(logged("Looking for the cube again in 2s (attempt 2)"))

        loop.attempt()

        #expect(radio.reaches.count == 1)
    }

    @Test func testTheBackoffGrowsWithEachFailedAttempt() {
        // `DeviceReconnectRules.delay` is 2, 4, 6 ... capped at 30, and the count is what the loop keeps. The rule is
        // tested on its own; this is the loop feeding it a count that actually rises.
        pair()
        let loop = reconnector()

        loop.noteDropped()
        loop.noteDropped()
        loop.noteDropped()

        #expect(logged("Looking for the cube again in 2s (attempt 2)"))
        #expect(logged("Looking for the cube again in 4s (attempt 3)"))
        #expect(logged("Looking for the cube again in 6s (attempt 4)"))
    }

    @Test func testAConnectionPutsTheBackoffBackToTheStart() {
        pair()
        let loop = reconnector()
        loop.noteDropped()
        loop.noteDropped()

        loop.noteOutcome(.loggedIn)
        loop.noteDropped()

        #expect(logged("The cube answered, so the backoff starts again from nothing"))
        #expect(logged("Looking for the cube again in 2s (attempt 2)"))
    }

    @Test func testNothingIsArrangedForADeviceThatHasBeenForgotten() {
        pair()
        let loop = reconnector()
        #expect(write("paired", "{\"paired\":false}"))

        loop.noteDropped()

        #expect(!logged("Looking for the cube again%"), "a forgotten device is not chased")
    }
}
