@testable import TimeFlipApp
import XCTest

/// The `icon` table is the only say in which icons exist. A hardcoded 42-name Swift array used to
/// filter it, so a row missing from the array vanished from the grid with nothing said; these pin down
/// that the table now decides and that a row it cannot draw is still offered.
final class IconPaletteTests: XCTestCase {
    private func record(_ id: Int, _ name: String) -> IconRecord {
        IconRecord(id: id, name: name)
    }

    /// The `None` sentinel at `icon_id` 0 is not an asset, and the grid clears an icon by re-clicking
    /// the selected one rather than offering a cell for "none".
    func testTheNoneSentinelIsTheOnlyRowSkipped() {
        let options = ActivityLibrary.iconOptions(from: [
            record(0, "None"),
            record(1, "ic_meeting"),
            record(2, "ic_break")
        ])

        XCTAssertEqual(options.map(\.iconId), [1, 2], "id 0 is dropped and nothing else is")
        XCTAssertEqual(options.map(\.iconName), ["ic_meeting", "ic_break"])
    }

    /// The behaviour change. `validIconNames` would have dropped this row for not being in the Swift
    /// array; the table is the authority now, so it is offered and draws as a placeholder. Silently
    /// omitting it is what made a mismatch between the DDL and the array invisible.
    func testARowNamingAnUnbundledAssetIsStillOffered() {
        let options = ActivityLibrary.iconOptions(from: [
            record(1, "ic_meeting"),
            record(2, "ic_not_a_real_asset")
        ])

        XCTAssertEqual(
            options.map(\.iconName), ["ic_meeting", "ic_not_a_real_asset"],
            "the table decides what exists, so an unknown name is a row to complain about rather than hide"
        )
    }

    /// Whatever the table holds is what the grid shows, in the table's own order -- no Swift-side list
    /// to agree with, so a row added to the DDL needs no code change to appear.
    func testEveryRowTheTableHoldsIsOfferedInOrder() {
        let names = (1...20).map { "ic_fixture_\($0)" }
        let options = ActivityLibrary.iconOptions(from: names.enumerated().map { record($0.offset + 1, $0.element) })

        XCTAssertEqual(options.count, 20)
        XCTAssertEqual(options.map(\.iconName), names)
    }

    /// The display label is derived from the asset name, so it needs no column and no lookup table.
    func testTheLabelIsDerivedFromTheAssetName() {
        let options = ActivityLibrary.iconOptions(from: [record(1, "ic_you_tube")])
        XCTAssertEqual(options.first?.name, "You Tube")
    }

    /// The real database's rows, all of which must resolve to bundled artwork -- the check that used to
    /// be a second list in Swift, now made against the bundle itself. A failure here means the DDL and
    /// `Resources/Icons` have drifted apart.
    func testEveryIconInTheShippedDDLResolvesToBundledArtwork() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("TimeFlipIconPalette", isDirectory: true)
            .appendingPathComponent("appdata.sqlite")
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        let store = AppDataStore(databaseURL: url)

        let options = ActivityLibrary.iconOptions(from: store.loadIcons())
        try XCTSkipIf(options.isEmpty, "the DDL resource did not load, so there is nothing to check")

        let unresolvable = options
            .filter { ActivityIconLoader.image(named: $0.iconName, pointSize: 16) == nil }
            .map { "\($0.iconId)=\($0.iconName)" }
        XCTAssertEqual(
            unresolvable, [],
            "every icon row the DDL seeds must have its SVG bundled, or the grid draws a placeholder for it"
        )
    }
}
