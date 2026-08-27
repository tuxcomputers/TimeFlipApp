@testable import FacetApp
import Foundation
import XCTest

/// `config.json`, the one place a developer build writes down the PIN it put on a cube.
///
/// **Every one of these runs against a file in a temporary directory**, never `DeveloperConfigFile.standard`: these
/// tests would otherwise rewrite the PIN of the cube this rebuild is tested against, which is the one value in the
/// app that a wrong write cannot be recovered from by re-running anything.
final class DeveloperConfigFileTests: XCTestCase {
    private var directory: URL!
    private var file: DeveloperConfigFile!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("facet-config-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        file = DeveloperConfigFile(url: directory.appendingPathComponent("config.json"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func write(_ text: String) throws {
        try Data(text.utf8).write(to: file.url)
    }

    private func read() throws -> [String: Any] {
        let data = try Data(contentsOf: file.url)
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // MARK: - reading

    func testThePINIsReadFromTheArchivesOwnKey() throws {
        // `PIN`, copied as it stands rather than renamed: a dev machine's file already holds the PIN of a real cube
        // under that name, and a new one would strand it.
        try write(#"{"PIN": "123456"}"#)
        XCTAssertEqual(file.pin(), "123456")
    }

    func testAFileThatIsNotThereNamesNoPIN() {
        // The ordinary case on a machine that has never set one, and what puts the vendor default on its own.
        XCTAssertNil(file.pin())
    }

    func testAFileThatNamesNoPINIsNotAnError() throws {
        try write(#"{"client_id": "something.apps.googleusercontent.com"}"#)
        XCTAssertNil(file.pin())
    }

    func testAMalformedFileIsTreatedAsAnEmptyOne() throws {
        // Refusing to connect because a JSON file has a stray comma in it would be a lockout caused by a text editor.
        try write("{ not json at all")
        XCTAssertNil(file.pin())
    }

    func testAPINTheCharacteristicCouldNotHoldIsNotAPIN() throws {
        // Six bytes wide, fixed by the protocol. Handing this on as a candidate would spend a whole reconnect on a
        // write the cube refuses.
        try write(#"{"PIN": "12345"}"#)
        XCTAssertNil(file.pin())
    }

    // MARK: - writing

    func testRecordingAPINPutsItWhereTheNextReadLooks() {
        XCTAssertTrue(file.record(pin: "123456"))
        XCTAssertEqual(file.pin(), "123456")
    }

    func testRecordingAPINCreatesTheFileWhenThereIsNone() throws {
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.url.path))
        XCTAssertTrue(file.record(pin: "123456"))
        XCTAssertEqual(try read()["PIN"] as? String, "123456")
    }

    func testRecordingAPINLeavesEverythingElseInTheFileAlone() throws {
        // **The one place this parts company with the archive**, which encoded a three-field payload over the whole
        // file. That was safe only because those three fields were the whole file; this build reads its Google
        // credentials elsewhere, so the same shape would quietly delete a developer's.
        try write(#"{"PIN": "000000", "client_id": "an-id", "client_secret": "a-secret"}"#)

        XCTAssertTrue(file.record(pin: "123456"))

        let contents = try read()
        XCTAssertEqual(contents["PIN"] as? String, "123456")
        XCTAssertEqual(contents["client_id"] as? String, "an-id")
        XCTAssertEqual(contents["client_secret"] as? String, "a-secret")
    }

    func testRecordingOverAMalformedFileStillLeavesAReadablePIN() throws {
        // Something has to give here, and it is the unreadable bytes rather than the PIN: the cube is already on the
        // new one by the time this runs, so a write refused on account of the old contents would lose it.
        try write("{ not json at all")
        XCTAssertTrue(file.record(pin: "123456"))
        XCTAssertEqual(file.pin(), "123456")
    }

    func testAWriteThatCouldNotLandIsReportedRatherThanAssumed() throws {
        // The answer comes from reading the file back, so a path that cannot be written says so instead of returning
        // a success nobody checked. A caller that believed it would think it knows a PIN only the cube has.
        //
        // The path is blocked by a *file* standing where a directory would have to be, because a missing directory is
        // not blocked at all: `record` makes the folder, which is what lets a machine that has never run this app
        // write its first PIN.
        let blocked = directory.appendingPathComponent("in-the-way")
        try Data("not a directory".utf8).write(to: blocked)

        let unwritable = DeveloperConfigFile(url: blocked.appendingPathComponent("config.json"))

        XCTAssertFalse(unwritable.record(pin: "123456"))
    }

    // MARK: - which build has one at all

    func testOnlyADeveloperBuildHasAConfigFile() {
        // A build without the developer flag has no `config.json`, in the same way it has no `debug_log` rows: an
        // absent facility is clearer than one that exists and declines.
        XCTAssertEqual(DeveloperConfigFile.standard != nil, DeveloperMode.isDeveloperMode)
    }

    func testTheStandardFileSitsBesideTheDatabase() throws {
        // `~/Library/Application Support/Facet/config.json`: the archive's location, under this app's name. It has to
        // outlive a database swap, which is the reason a PIN is not a `setting` row in the first place.
        try XCTSkipIf(!DeveloperMode.isDeveloperMode)
        let url = try XCTUnwrap(DeveloperConfigFile.standard).url
        XCTAssertEqual(url.lastPathComponent, "config.json")
        XCTAssertEqual(url.deletingLastPathComponent().lastPathComponent, "Facet")
    }
}
