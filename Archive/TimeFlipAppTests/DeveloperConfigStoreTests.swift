@testable import TimeFlipApp
import XCTest

/// Covers `DeveloperConfigStore`, the real file-backed store behind `config.json` -- as opposed to
/// `DeveloperConfigWriteBackTests`, which exercises `AppState`'s write-back rules against an
/// in-memory double and has no serialization step of its own, so it can't represent a hand-edited
/// file that fails to decode.
final class DeveloperConfigStoreTests: XCTestCase {
    private var directory: URL!
    private var configURL: URL!

    override func setUp() {
        super.setUp()
        directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("DeveloperConfigStoreTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        configURL = directory.appendingPathComponent("config.json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    func testLoadReturnsNilWhenTheFileDoesNotExist() {
        let store = DeveloperConfigStore(fileURL: configURL)

        XCTAssertNil(store.load())
    }

    func testLoadFailsSoftOnAHandEditedFileThatDoesNotDecode() throws {
        // config.json's whole premise is manual editing, so a stray comma or a half-finished edit
        // left mid-save is a realistic state to find it in. load() must fail soft, the same way a
        // missing file does, rather than crash the app on the next launch.
        try Data("{ this is not valid json,,, }".utf8).write(to: configURL)
        let store = DeveloperConfigStore(fileURL: configURL)

        XCTAssertNil(store.load())
    }

    func testAValidFileRoundTripsThroughSaveAndLoad() {
        // Sanity check for the test above: confirms the fixture there is exercising a genuine decode
        // failure against a store that can otherwise read back what it wrote, not a store that
        // always returns nil regardless of the file's contents.
        let store = DeveloperConfigStore(fileURL: configURL)
        store.save(DeveloperConfigPayload(googleClientID: "id", googleClientSecret: "secret", devicePassword: "123456"))

        let loaded = store.load()

        XCTAssertEqual(loaded?.googleClientID, "id")
        XCTAssertEqual(loaded?.googleClientSecret, "secret")
        XCTAssertEqual(loaded?.devicePassword, "123456")
    }
}
