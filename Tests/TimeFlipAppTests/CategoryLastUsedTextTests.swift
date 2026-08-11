@testable import TimeFlipApp
import XCTest

/// What sits to the right of a category's Active box.
///
/// The interesting rules are the two absences: nothing on an active row, and a worded answer rather
/// than a blank one when a retired category has no recorded time. Both are easy to get wrong in a
/// way that looks fine on the screen the developer happens to be looking at, since most rows in a
/// real database have a date and are active.
final class CategoryLastUsedTextTests: XCTestCase {
    /// Fixed locale and zone: the label is deliberately localised, so without pinning both, this
    /// suite would pass or fail on the machine's region settings.
    private let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_GB")
        formatter.timeZone = TimeZone(identifier: "Australia/Sydney")
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    private func label(isActive: Bool, lastUsed: Date?) -> String? {
        CategoryLastUsedText.label(isActive: isActive, lastUsed: lastUsed, formatter: formatter)
    }

    /// An active category is one being used now, so the date would be noise on every row that
    /// matters day to day.
    func testAnActiveCategoryShowsNothingEvenWhenItHasRecordedTime() {
        XCTAssertNil(label(isActive: true, lastUsed: Date(timeIntervalSince1970: 1_786_000_000)))
    }

    func testAnActiveCategoryWithNoRecordedTimeAlsoShowsNothing() {
        XCTAssertNil(label(isActive: true, lastUsed: nil))
    }

    /// The expected string is the epoch converted independently of the code under test
    /// (`TZ=Australia/Sydney date -r 1786000000`, which is 07:06 UTC), so this pins the conversion
    /// rather than agreeing with whatever the formatter happened to produce.
    func testARetiredCategoryShowsWhenItLastRecordedTime() {
        let text = label(isActive: false, lastUsed: Date(timeIntervalSince1970: 1_786_000_000))
        XCTAssertEqual(text, "6 Aug 2026 at 17:06")
    }

    /// The case the Inactive list exists to answer. `UN1_category` allows any number of retired
    /// categories to share a name, so two identical rows can sit there owning different history;
    /// "Never" under the "Last used" header is the whole answer about which one to reinstate, and a
    /// blank cell would read as a row that failed to load rather than one with nothing behind it.
    func testARetiredCategoryThatNeverRecordedTimeSaysSo() {
        XCTAssertEqual(label(isActive: false, lastUsed: nil), "Never")
    }

    /// The date has to survive a patch, because the one edit an inactive row allows is the Active
    /// box sitting immediately left of it -- `CategoryRow` re-renders from the patched record, so a
    /// `with(...)` that dropped `lastUsed` would blank the label the instant anyone touched it.
    func testPatchingARecordKeepsItsLastUsedDate() {
        let used = Date(timeIntervalSince1970: 1_786_000_000)
        let record = CategoryRecord(
            id: 7,
            name: "Email",
            iconID: 0,
            colourID: 0,
            isActive: false,
            dailyLimitMinutes: 0,
            lastUsed: used
        )
        XCTAssertEqual(record.with(isActive: true).lastUsed, used)
        XCTAssertEqual(record.with(name: "Inbox").lastUsed, used)
    }

    /// The readers that do not fill it must still compile and behave, so the field defaults rather
    /// than forcing every construction site to supply a date it has no query for.
    func testLastUsedDefaultsToNothingWhenNotSupplied() {
        let record = CategoryRecord(
            id: 7,
            name: "Email",
            iconID: 0,
            colourID: 0,
            isActive: false,
            dailyLimitMinutes: 0
        )
        XCTAssertNil(record.lastUsed)
        XCTAssertEqual(label(isActive: record.isActive, lastUsed: record.lastUsed), "Never")
    }
}
