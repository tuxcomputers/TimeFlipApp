@testable import FacetApp
import AppKit
import XCTest

/// Covers `SteppedNumberField`: what it reports, and what it refuses to report.
///
/// The behaviours worth pinning are the archive's findings rather than obvious choices: a value out of range is
/// clamped rather than refused, and an arrow steps from the number on screen rather than from the number in storage.
///
/// The arrows are pressed rather than held. What a *hold* does is `StepperHoldRules`, tested on its own, which is
/// the reason that rule is a separate type at all -- driving it here would mean holding a real mouse button down for
/// several seconds.
@MainActor
final class SteppedNumberFieldTests: XCTestCase {
    private func field(value: Int = 0, range: ClosedRange<Int> = 0 ... 1_440) -> SteppedNumberField {
        SteppedNumberField(value: value, range: range, suffix: "min", identifier: "limit")
    }

    private func textField(of field: SteppedNumberField) -> NSTextField? {
        field.subviews.compactMap { $0 as? NSTextField }.first { $0.isEditable }
    }

    private func arrows(of field: SteppedNumberField) -> [HoldArrow] {
        field.subviews.flatMap { $0.subviews }.compactMap { $0 as? HoldArrow }
    }

    private func arrow(_ direction: Int, of field: SteppedNumberField) throws -> HoldArrow {
        try XCTUnwrap(arrows(of: field).first { $0.direction == direction })
    }

    // MARK: - showing a value

    func testItShowsTheValueItWasGiven() throws {
        let field = field(value: 45)

        XCTAssertEqual(field.value, 45)
        XCTAssertEqual(try XCTUnwrap(textField(of: field)).integerValue, 45)
    }

    func testAValueOutOfRangeIsBroughtInsideItOnTheWayIn() {
        XCTAssertEqual(field(value: 9_999).value, 1_440)
        XCTAssertEqual(field(value: -5).value, 0)
    }

    func testSettingTheValueDoesNotReportIt() {
        // This is how the value is put there, not how it is changed: a report would be the field telling its owner
        // what its owner just told it.
        let field = field(value: 10)
        var reported: [Int] = []
        field.onChange = { reported.append($0) }

        field.value = 20

        XCTAssertEqual(field.value, 20)
        XCTAssertTrue(reported.isEmpty)
    }

    // MARK: - typing

    func testATypedValueIsReportedOnce() throws {
        let field = field(value: 10)
        var reported: [Int] = []
        field.onChange = { reported.append($0) }

        let box = try XCTUnwrap(textField(of: field))
        box.integerValue = 90
        box.sendAction(box.action, to: box.target)

        XCTAssertEqual(reported, [90])
    }

    func testATypedValueOutOfRangeIsClampedAndShownAsClamped() throws {
        let field = field(value: 10)
        var reported: [Int] = []
        field.onChange = { reported.append($0) }

        let box = try XCTUnwrap(textField(of: field))
        box.integerValue = 9_999
        box.sendAction(box.action, to: box.target)

        // Reported as the allowed value, and the box now shows it: a field still reading 9999 would be claiming a
        // value nothing agreed to.
        XCTAssertEqual(reported, [1_440])
        XCTAssertEqual(box.integerValue, 1_440)
    }

    func testTypingTheValueItAlreadyHasReportsNothing() throws {
        let field = field(value: 10)
        var reported: [Int] = []
        field.onChange = { reported.append($0) }

        let box = try XCTUnwrap(textField(of: field))
        box.integerValue = 10
        box.sendAction(box.action, to: box.target)

        XCTAssertTrue(reported.isEmpty)
    }

    // MARK: - the arrows

    func testThereIsAnArrowEachWay() throws {
        let field = field()

        XCTAssertEqual(arrows(of: field).map(\.direction).sorted(), [-1, 1])
        // Named for a script and for a screen reader, since a chevron says nothing to either.
        XCTAssertEqual(try arrow(1, of: field).accessibilityIdentifier(), "limit-up")
        XCTAssertEqual(try arrow(-1, of: field).accessibilityLabel(), "Decrease")
    }

    func testOneClickIsOneStep() throws {
        let field = field(value: 10)
        var reported: [Int] = []
        field.onChange = { reported.append($0) }

        try arrow(1, of: field).performClick(nil)

        XCTAssertEqual(reported, [11])
        XCTAssertEqual(field.value, 11)
    }

    func testTheDownArrowStepsDown() throws {
        let field = field(value: 10)

        try arrow(-1, of: field).performClick(nil)

        XCTAssertEqual(field.value, 9)
    }

    func testAnArrowStepsFromWhatIsOnScreenRatherThanFromWhatIsStored() throws {
        // The archive's rule, with its reasoning: type 20 into a field holding 5, click up without pressing Return,
        // and the answer is 21, because the visible text is what somebody believes the value to be.
        let field = field(value: 5)
        var reported: [Int] = []
        field.onChange = { reported.append($0) }

        try XCTUnwrap(textField(of: field)).stringValue = "20"
        try arrow(1, of: field).performClick(nil)

        XCTAssertEqual(reported, [21])
        XCTAssertEqual(field.value, 21)
    }

    func testAnUnparseableEntryFallsBackToTheStoredValue() throws {
        // Garbage falls back to the last number actually chosen rather than to zero: the same rule the typed commit
        // follows, so an arrow after a typo does not silently reset the field.
        let field = field(value: 30)

        try XCTUnwrap(textField(of: field)).stringValue = "twelve"
        try arrow(1, of: field).performClick(nil)

        XCTAssertEqual(field.value, 31)
    }

    func testAnEntryAboveTheRangeStillStepsFromInsideIt() throws {
        // Typing 9999 into a field capped at 1440 and pressing down has to go to 1439, not to 9998.
        let field = field(value: 30)

        try XCTUnwrap(textField(of: field)).stringValue = "9999"
        try arrow(-1, of: field).performClick(nil)

        XCTAssertEqual(field.value, 1_439)
    }

    func testTheArrowsCannotLeaveTheRange() throws {
        let field = field(value: 0)
        var reported: [Int] = []
        field.onChange = { reported.append($0) }

        try arrow(-1, of: field).performClick(nil)

        XCTAssertTrue(reported.isEmpty, "already at the bottom, so nothing moved")
        XCTAssertEqual(field.value, 0)
    }

    func testTheTopOfTheRangeIsReachableButNotPassable() throws {
        let field = field(value: 1_439)

        try arrow(1, of: field).performClick(nil)
        XCTAssertEqual(field.value, 1_440)

        try arrow(1, of: field).performClick(nil)
        XCTAssertEqual(field.value, 1_440)
    }
}
