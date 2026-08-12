import XCTest
@testable import TimeFlipApp

final class CategoryDisplayOrderTests: XCTestCase {
    private func category(_ id: Int, _ name: String) -> CategoryRecord {
        CategoryRecord(id: id, name: name, iconID: 0, colourID: 0, isActive: true, dailyLimitMinutes: 0)
    }

    private func sortedNames(_ names: [String]) -> [String] {
        names.enumerated()
            .map { category($0.offset + 1, $0.element) }
            .sorted(by: CategoryRecord.displayOrder)
            .map(\.name)
    }

    func testNumericNamesSortNumericallyNotAsText() {
        // The reported bug: a plain text sort gives 1, 10, 11, 2, 20, 3.
        XCTAssertEqual(
            sortedNames(["1", "10", "11", "2", "20", "3"]),
            ["1", "2", "3", "10", "11", "20"]
        )
    }

    func testNumbersSortBeforeText() {
        XCTAssertEqual(
            sortedNames(["Meeting", "2", "Break", "10", "1"]),
            ["1", "2", "10", "Break", "Meeting"]
        )
    }

    func testTextSortsCaseInsensitively() {
        XCTAssertEqual(sortedNames(["banana", "Apple", "cherry"]), ["Apple", "banana", "cherry"])
    }

    func testEmbeddedNumbersUseNaturalOrder() {
        // Not strictly required by the numbers-then-text rule, but localizedStandardCompare gives
        // it for free and it is what anyone naming categories after tickets would expect.
        XCTAssertEqual(
            sortedNames(["ACME-10", "ACME-2", "ACME-1"]),
            ["ACME-1", "ACME-2", "ACME-10"]
        )
    }

    func testEquivalentNumbersAreOrderedDeterministicallyByID() {
        // "1" and "01" are the same number, and localizedStandardCompare treats them as equal text
        // too (it compares digit runs numerically), so the id tiebreak is what settles it.
        let records = [category(9, "01"), category(4, "1")]
        XCTAssertEqual(records.sorted(by: CategoryRecord.displayOrder).map(\.name), ["1", "01"])
    }

    func testDuplicateNamesAreOrderedByIDSoTheSortIsDeterministic() {
        // Duplicate names are a legitimate outcome of the create flow's "same name again" choice.
        let records = [category(7, "Meeting"), category(3, "Meeting"), category(5, "Meeting")]
        XCTAssertEqual(records.sorted(by: CategoryRecord.displayOrder).map(\.id), [3, 5, 7])
    }

    func testNameTooLongForAnIntIsTreatedAsText() {
        let huge = String(repeating: "9", count: 40)
        // Falls to the text side, so it sorts after a real number rather than ahead of everything.
        XCTAssertEqual(sortedNames([huge, "5"]), ["5", huge])
    }
}
