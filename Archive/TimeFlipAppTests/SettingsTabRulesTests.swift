@testable import TimeFlipApp
import XCTest

/// Which tab Settings lands on when it opens, and when it leaves the user's own last choice alone.
final class SettingsTabRulesTests: XCTestCase {
    private func tab(manual: Bool = false, lowBattery: Bool = false) -> SettingsTab? {
        SettingsTabRules.tabOnOpen(isManualMode: manual, isLowBatteryBlinking: lowBattery)
    }

    func testManualModeAlwaysOpensOnFaces() {
        XCTAssertEqual(tab(manual: true), .faces)
    }

    func testManualModeOutranksALowBatteryBlink() {
        // A blink can only be left over from before the device went away, manual mode never reading
        // a battery at all. Pinned so the precedence is deliberate, and matching MenuBarClickRouter,
        // where manual mode also wins.
        XCTAssertEqual(tab(manual: true, lowBattery: true), .faces)
    }

    func testALowBatteryBlinkOpensOnDevice() {
        XCTAssertEqual(tab(lowBattery: true), .timeflip)
    }

    func testOtherwiseTheLastTabIsKept() {
        // nil means "don't touch it". The window is only ordered out on close, so the tab the user
        // left it on is still selected, and reopening on it is what they expect.
        XCTAssertNil(tab())
    }
}
