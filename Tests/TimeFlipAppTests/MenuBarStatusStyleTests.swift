@testable import TimeFlipApp
import AppKit
import XCTest

/// Covers the menu bar status title's color/badge selection (`MenuBarStatusStyle`), extracted from
/// `MenuBarController.makeStatusTitle`. This is the Tier-1 stand-in for the interactive "check the
/// red lock badge / pause icon / blink color appears" steps: it asserts the decision that drives
/// what gets drawn, without a status item or a device.
final class MenuBarStatusStyleTests: XCTestCase {
    private func make(
        isConnected: Bool = true,
        isPaused: Bool = false,
        overLimit: Bool = false,
        isLowBattery: Bool = false,
        blinkPhaseOn: Bool = false,
        isLocked: Bool = false
    ) -> MenuBarStatusStyle {
        MenuBarStatusStyle.make(
            isConnected: isConnected,
            isPaused: isPaused,
            overLimit: overLimit,
            isLowBattery: isLowBattery,
            blinkPhaseOn: blinkPhaseOn,
            isLocked: isLocked
        )
    }

    func testConnectedRunningWithinLimitIsGreen() {
        let style = make()
        XCTAssertEqual(style.steadyColor, .systemGreen)
        XCTAssertEqual(style.categoryColor, .systemGreen)
        XCTAssertFalse(style.showsPauseIcon)
        XCTAssertFalse(style.indicatorOverLimit)
    }

    func testDisconnectedIsFlatYellowRegardlessOfEverythingElse() {
        // A stale over-limit / low-battery state must not bleed color through once disconnected.
        let style = make(isConnected: false, overLimit: true, isLowBattery: true, blinkPhaseOn: true)
        XCTAssertEqual(style.steadyColor, .systemYellow)
        XCTAssertEqual(style.categoryColor, .systemYellow)
    }

    func testOverLimitTurnsBothTheTextAndIndicatorRed() {
        let style = make(overLimit: true)
        XCTAssertEqual(style.steadyColor, .systemRed)
        XCTAssertEqual(style.categoryColor, .systemRed)
        XCTAssertTrue(style.indicatorOverLimit)
    }

    func testLowBatteryBlinksTheCategoryRedThenWhite() {
        // The label alternates red (blink on) / white (blink off) while the steady duration text
        // stays on its normal green.
        let on = make(isLowBattery: true, blinkPhaseOn: true)
        XCTAssertEqual(on.categoryColor, .systemRed)
        XCTAssertEqual(on.steadyColor, .systemGreen)

        let off = make(isLowBattery: true, blinkPhaseOn: false)
        XCTAssertEqual(off.categoryColor, .white)
        XCTAssertEqual(off.steadyColor, .systemGreen)
    }

    func testLowBatteryWinsOverOverLimitForTheCategoryColor() {
        // Low battery always wins the category color; the steady (duration) color still reflects
        // the over-limit red underneath.
        let style = make(overLimit: true, isLowBattery: true, blinkPhaseOn: true)
        XCTAssertEqual(style.categoryColor, .systemRed)
        XCTAssertEqual(style.steadyColor, .systemRed)
    }

    func testLockBadgeShownOnlyWhenLocked() {
        XCTAssertFalse(make(isLocked: false).showsLockBadge)
        XCTAssertTrue(make(isLocked: true).showsLockBadge)
    }

    func testLockedStillReportsUnderlyingPauseOrPlayIcon() {
        // The lock badge sits beside the pause/play indicator, not in place of it -- whether the
        // device is still timing stays visible while locked.
        XCTAssertTrue(make(isPaused: true, isLocked: true).showsPauseIcon)
        XCTAssertFalse(make(isPaused: false, isLocked: true).showsPauseIcon)
    }

    func testPausedShowsPauseIcon() {
        XCTAssertTrue(make(isPaused: true).showsPauseIcon)
    }
}
