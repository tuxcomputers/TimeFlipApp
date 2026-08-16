@testable import TimeFlipApp
import SQLite3
import XCTest

/// Face 13, the one manual mode owns.
///
/// Two bounds exist on purpose and the tests below are mostly about keeping them apart: what a cube
/// may report (still 12) and what the app may store (13). Collapsing them would tell the BLE parser
/// that a TimeFlip2 can send a thirteenth face, which it cannot -- a frame claiming 13 is a corrupt
/// frame, and it has to stay one.
final class ManualFaceStorageTests: XCTestCase {
    private var directory: URL!
    private var dbURL: URL!

    override func setUp() {
        super.setUp()
        directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("ManualFaceStorageTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        dbURL = directory.appendingPathComponent("appdata.sqlite")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    // MARK: - The two bounds

    func testACubeStillCannotReportFaceThirteen() {
        XCTAssertFalse(TimeFlipConstants.isValidFaceID(TimeFlipConstants.manualFaceID))
        XCTAssertEqual(TimeFlipConstants.maxFaceID, 12)
        XCTAssertEqual(TimeFlipConstants.faceIDs.count, 12)
    }

    func testTheAppMayStoreFaceThirteen() {
        XCTAssertTrue(TimeFlipConstants.isValidStoredFaceID(TimeFlipConstants.manualFaceID))
    }

    func testBothBoundsRejectZeroAndFourteen() {
        // Face 0 is the `unassignedFaceID` sentinel, not a face, and must never create a row.
        for faceID in [TimeFlipConstants.unassignedFaceID, 14] as [UInt8] {
            XCTAssertFalse(TimeFlipConstants.isValidFaceID(faceID), "face \(faceID)")
            XCTAssertFalse(TimeFlipConstants.isValidStoredFaceID(faceID), "face \(faceID)")
        }
    }

    func testTheTwelveCubeFacesSatisfyBoth() {
        for faceID in TimeFlipConstants.faceIDs {
            XCTAssertTrue(TimeFlipConstants.isValidFaceID(faceID), "face \(faceID)")
            XCTAssertTrue(TimeFlipConstants.isValidStoredFaceID(faceID), "face \(faceID)")
        }
    }

    // MARK: - The database

    func testFaceThirteenIsSeeded() {
        // Seeded like the other twelve, so manual mode has a face to put a category on from the
        // first launch rather than needing one created at the moment it is first used.
        let store = AppDataStore(databaseURL: dbURL)
        XCTAssertNotNil(store.loadFaceCategories()[TimeFlipConstants.manualFaceID])
    }

    func testFaceThirteenTakesACategory() {
        let store = AppDataStore(databaseURL: dbURL)
        guard let category = store.loadCategories().first(where: { $0.name != "Unassigned" }) else {
            return XCTFail("expected a seeded category to assign")
        }
        store.updateFaceCategory(faceID: TimeFlipConstants.manualFaceID, categoryID: category.id)
        XCTAssertEqual(store.loadFaceCategories()[TimeFlipConstants.manualFaceID]?.id, category.id)
    }

    func testFaceFourteenIsStillRefused() {
        // The guard on the write is what stops a stray face id creating a row of its own; widening
        // it to 13 must not have widened it to anything.
        let store = AppDataStore(databaseURL: dbURL)
        guard let category = store.loadCategories().first(where: { $0.name != "Unassigned" }) else {
            return XCTFail("expected a seeded category to assign")
        }
        store.updateFaceCategory(faceID: 14, categoryID: category.id)
        XCTAssertNil(store.loadFaceCategories()[14])
    }

    func testADeviceEventOnFaceThirteenIsAccepted() {
        // The CHECK on device_event.device_face stopped at 12, so a manual segment could not be
        // written at all until the table was rebuilt. Nothing else in the app would have reported
        // that: the insert fails, is logged, and the segment silently never exists.
        let store = AppDataStore(databaseURL: dbURL)
        let written = store.recordDeviceEvent(
            eventNumber: 900_501,
            deviceFace: TimeFlipConstants.manualFaceID,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            durationSeconds: 90,
            isPaused: false
        )
        XCTAssertTrue(written)
    }

    // MARK: - Resuming a device fetch past a manual session

    func testAManualSegmentIsNeverTheResumePosition() {
        // Manual rows sit in the same table but were never part of any device's history, and their
        // event numbers are seeded from the wall clock, so they land around 1.79 billion against a
        // cube's few hundred. Counted as the newest recorded event, the next launch reads the stored
        // position as unreachable and re-fetches the cube's whole history from zero.
        let store = AppDataStore(databaseURL: dbURL)
        store.recordDeviceEvent(
            eventNumber: 139,
            deviceFace: 2,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            durationSeconds: 600,
            isPaused: false
        )
        store.recordDeviceEvent(
            eventNumber: 1_786_000_000,
            deviceFace: TimeFlipConstants.manualFaceID,
            startedAt: Date(timeIntervalSince1970: 1_700_001_000),
            durationSeconds: 300,
            isPaused: false
        )

        // Newer by start_epoch and far higher by number, and still not the answer.
        XCTAssertEqual(store.latestRecordedEvent()?.eventNumber, 139)
    }

    func testWithOnlyManualSegmentsThereIsNoResumePosition() {
        // A launch that has only ever run manually leaves nothing to resume from, which reads as a
        // fresh start rather than as a position the device will fail to reach.
        let store = AppDataStore(databaseURL: dbURL)
        store.recordDeviceEvent(
            eventNumber: 1_786_000_001,
            deviceFace: TimeFlipConstants.manualFaceID,
            startedAt: Date(timeIntervalSince1970: 1_700_002_000),
            durationSeconds: 120,
            isPaused: false
        )
        XCTAssertNil(store.latestRecordedEvent())
    }

    func testADeviceEventOnFaceFourteenIsRefusedByTheCheck() {
        let store = AppDataStore(databaseURL: dbURL)
        let written = store.recordDeviceEvent(
            eventNumber: 900_502,
            deviceFace: 14,
            startedAt: Date(timeIntervalSince1970: 1_700_000_100),
            durationSeconds: 90,
            isPaused: false
        )
        XCTAssertFalse(written, "the CHECK should still stop anything above the manual face")
    }
}
