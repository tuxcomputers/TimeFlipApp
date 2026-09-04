@testable import FacetApp
import AppKit
import XCTest

/// Covers the Report tab's folding categories: what a closed group asks for, what an open one draws, and how a stretch
/// is written out.
@MainActor
final class ReportCategoryGroupTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func at(_ text: String) -> Date {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.date(from: text)!
    }

    private func total(_ name: String = "Break", seconds: TimeInterval = 900, id: Int = 1) -> CategoryTotal {
        CategoryTotal(
            categoryID: id,
            name: name,
            iconName: nil,
            colour: .red,
            usesWhiteLines: false,
            seconds: seconds
        )
    }

    private func entry(_ id: Int, _ start: String, _ end: String) -> TimeEntryRecord {
        TimeEntryRecord(timeEntryID: id, start: at(start), end: at(end))
    }

    private func descendants(of root: NSView) -> [NSView] {
        root.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    private func labels(of root: NSView) -> [String] {
        descendants(of: root).compactMap { ($0 as? NSTextField)?.stringValue }
    }

    private func headingButton(of group: ReportCategoryGroup) throws -> NSButton {
        try XCTUnwrap(
            descendants(of: group).compactMap { $0 as? NSButton }.first {
                $0.accessibilityIdentifier().hasSuffix("-heading")
            }
        )
    }

    private func made(
        _ total: CategoryTotal,
        showingSeconds: Bool = true,
        entries: [TimeEntryRecord] = []
    ) -> ReportCategoryGroup {
        let group = ReportCategoryGroup(total: total, showingSeconds: showingSeconds, calendar: calendar)
        group.entries = { entries }
        return group
    }

    // MARK: - closed

    func testAGroupStartsClosedAndAsksForNothing() {
        // The totals are the answer to the range; the entries are the working, and nobody wants twelve categories of
        // working at once. A closed group costs no read at all.
        var asked = 0
        let group = ReportCategoryGroup(total: total(), showingSeconds: false, calendar: calendar)
        group.entries = {
            asked += 1
            return []
        }

        XCTAssertFalse(group.isExpanded)
        XCTAssertEqual(asked, 0)
        XCTAssertTrue(labels(of: group).contains("0:15"), "the total is on the heading line")
    }

    func testAClosedGroupIsOnlyItsHeading() {
        let group = made(total(), entries: [entry(1, "2026-08-13 09:00:00", "2026-08-13 09:15:00")])
        group.frame = NSRect(x: 0, y: 0, width: 600, height: 200)
        group.layoutSubtreeIfNeeded()

        XCTAssertEqual(group.frame.height, ReportCategoryGroup.Layout.rowHeight)
    }

    func testALongNameGivesWayBeforeTheFigureDoes() throws {
        // The row is built to truncate the name rather than cut the figure the row exists to show, and equal
        // priorities made that a comment rather than a behaviour: both held out for their own width, so the window
        // widened to hold whatever somebody had typed. **Measured on the Faces tab, the same fault**: a 56-character
        // name drew the Settings window 1295pt wide.
        let group = made(total("When there is a long category it makes the windows wider"))

        let fields = descendants(of: group).compactMap { $0 as? NSTextField }
        let name = try XCTUnwrap(fields.first { $0.stringValue.hasPrefix("When there is") })
        let figure = try XCTUnwrap(fields.first { $0.stringValue.contains(":") })

        XCTAssertEqual(name.contentCompressionResistancePriority(for: .horizontal), .defaultLow)
        XCTAssertGreaterThan(
            figure.contentCompressionResistancePriority(for: .horizontal),
            name.contentCompressionResistancePriority(for: .horizontal),
            "which is the whole of what makes the name give way first"
        )
    }

    // MARK: - opening

    func testTheWholeHeadingLineOpensTheGroupRatherThanJustTheTriangle() throws {
        // The rule in CLAUDE.md, for every collapsible group the app grows.
        let group = made(total(), entries: [entry(1, "2026-08-13 09:00:00", "2026-08-13 09:15:00")])
        var reported: [Bool] = []
        group.onToggle = { reported.append($0) }

        try headingButton(of: group).performClick(nil)

        XCTAssertTrue(group.isExpanded)
        XCTAssertEqual(reported, [true])
        XCTAssertNotNil(
            descendants(of: group).first { $0.accessibilityIdentifier() == "report-entry-1" },
            "and the entries are there"
        )
    }

    func testTheHeadingsPartsAreInsideTheButtonRatherThanBesideIt() throws {
        // The trap that has shipped twice in this app: a click on a label goes up the responder chain to the label's own
        // *superview*, so a button merely sitting behind one is never reached.
        let group = made(total("Meeting", seconds: 60, id: 2))

        let heading = try headingButton(of: group)
        XCTAssertTrue(labels(of: heading).contains("Meeting"))
        XCTAssertTrue(labels(of: heading).contains("0:01:00"), "the figure too, so the whole line presses")
    }

    func testTheEntriesAreReadWhenTheGroupIsOpenedRatherThanBefore() throws {
        var asked = 0
        let group = ReportCategoryGroup(total: total(), showingSeconds: false, calendar: calendar)
        group.entries = {
            asked += 1
            return [self.entry(1, "2026-08-13 09:00:00", "2026-08-13 09:15:00")]
        }

        group.setExpanded(true)
        XCTAssertEqual(asked, 1)

        // Closing throws the rows away, so re-opening reads again: the figures can have changed while it was shut.
        group.setExpanded(false)
        group.setExpanded(true)
        XCTAssertEqual(asked, 2)
        XCTAssertEqual(
            descendants(of: group).filter { $0.accessibilityIdentifier() == "report-entry-1" }.count, 1,
            "and the row is not drawn twice"
        )
    }

    func testAnOpenGroupIsTallerThanItsHeading() {
        let group = made(total(), entries: [
            entry(1, "2026-08-13 09:00:00", "2026-08-13 09:15:00"),
            entry(2, "2026-08-13 11:00:00", "2026-08-13 11:05:00"),
        ])
        group.setExpanded(true)
        group.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        group.layoutSubtreeIfNeeded()

        XCTAssertEqual(
            group.frame.height,
            ReportCategoryGroup.Layout.rowHeight + 2 * ReportCategoryGroup.Layout.entryHeight
        )
    }

    // MARK: - what an entry says

    func testAnEntryReadsAsDayThenStartAndEndThenHowLong() throws {
        let group = made(total(), entries: [entry(1, "2026-08-13 09:07:03", "2026-08-13 09:26:15")])

        group.setExpanded(true)

        let row = descendants(of: group).first { $0.accessibilityIdentifier() == "report-entry-1" }
        XCTAssertEqual(labels(of: try XCTUnwrap(row)), ["13/08", "09:07:03", "\u{2013}", "09:26:15", "0:19:12"])
    }

    func testSecondsComeOffAllThreeFiguresTogether() throws {
        // One setting, one meaning. A 19-second entry at minute precision reading "13:08 to 13:08" is only honest if the
        // duration beside it reads 0:00 as well -- and that is why the setting is no longer named after the menu bar.
        let group = made(
            total(),
            showingSeconds: false,
            entries: [entry(1, "2026-08-13 13:08:47", "2026-08-13 13:09:06")]
        )

        group.setExpanded(true)

        let row = descendants(of: group).first { $0.accessibilityIdentifier() == "report-entry-1" }
        XCTAssertEqual(labels(of: try XCTUnwrap(row)), ["13/08", "13:08", "\u{2013}", "13:09", "0:00"])
    }

    func testTheDayIsDayThenMonthWhateverTheMachinesLocaleIs() {
        // Fixed rather than localised, deliberately: en_US would draw 08/13 and a 12-hour clock.
        XCTAssertEqual(ReportEntryText.date(at("2026-08-13 09:00:00"), calendar: calendar), "13/08")
        XCTAssertEqual(
            ReportEntryText.clock(at("2026-08-13 13:08:47"), showingSeconds: false, calendar: calendar),
            "13:08"
        )
    }

    func testARowIsSpokenAsWordsRatherThanAColumnOfDigits() {
        // A screen reader reading "13/08 09:07:03 09:26:15 0:19:12" conveys nothing.
        XCTAssertEqual(
            ReportEntryText.spoken(
                entry(1, "2026-08-13 09:07:03", "2026-08-13 09:26:15"),
                showingSeconds: true,
                calendar: calendar
            ),
            "13 August, 09:07:03 to 09:26:15, 0:19:12"
        )
    }

    // MARK: - the list around them

    func testEachCategoryGetsItsOwnGroupClosed() {
        let list = ReportTotalsList()

        // **Handed smallest first on purpose.** The list opens on the biggest figure, so an input already in that
        // order would pass this test without reordering anything and prove nothing.
        list.show([total("Break", seconds: 900), total("Meeting", seconds: 3_900, id: 2)], showingSeconds: false)

        // Handed Break first and drawn Meeting first: the list applies the order in force rather than the sequence
        // it was given.
        XCTAssertEqual(list.groups.map(\.total.name), ["Meeting", "Break"])
        XCTAssertTrue(list.groups.allSatisfy { !$0.isExpanded })
    }

    func testAGroupLeftOpenStaysOpenWhenTheListIsRebuilt() {
        // A pause elsewhere in the app turns a stretch into an entry and the totals are re-read; a list that snapped
        // shut underneath somebody would be the app undoing what they had just done.
        let list = ReportTotalsList()
        list.entries = { _ in [self.entry(1, "2026-08-13 09:00:00", "2026-08-13 09:15:00")] }
        list.show([total("Break", seconds: 900)], showingSeconds: false)
        list.groups[0].setExpanded(true)
        // Reported outward as a click would, since that is what records the state.
        list.groups[0].onToggle?(true)

        list.show([total("Break", seconds: 1_200)], showingSeconds: false)

        XCTAssertTrue(list.groups[0].isExpanded)
        XCTAssertTrue(labels(of: list).contains("0:20"), "showing the figure just read, not the one it was opened on")
    }

    func testACategoryThatDropsOutOfTheRangeIsNotHeldOpen() {
        let list = ReportTotalsList()
        list.show([total("Break", seconds: 900), total("Meeting", seconds: 60, id: 2)], showingSeconds: false)
        list.groups[0].setExpanded(true)
        list.groups[0].onToggle?(true)

        list.show([total("Meeting", seconds: 60, id: 2)], showingSeconds: false)

        XCTAssertEqual(list.groups.map(\.total.categoryID), [2])
        XCTAssertFalse(list.groups[0].isExpanded, "Meeting was never opened")
    }
}
