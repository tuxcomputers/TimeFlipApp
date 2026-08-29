@testable import FacetApp
import AppKit
import XCTest

/// Forgetting a device makes this app its own clock in the same moment, and the surfaces follow without being told.
///
/// **What this is really pinning is an absence.** Nothing holds a mode: timing by hand is what being unpaired means,
/// so every reader answers the new way the next time it asks, and there is no list of things to notify that a new
/// surface could be left off. That was the fault the mode was reversed for on 2026-08-23, and deriving the answer
/// removes the possibility rather than adding a fourth place to catch it.
///
/// **Except one, and it is here too.** The menu bar repaints on a tick that only runs while something is being timed,
/// so a pairing that changes while nothing is running would leave it drawn for the app it was. That is a redraw rather
/// than a second copy of the answer, and `onTimingChanged` is the funnel every other path already uses.
///
/// **The other direction is pinned where it can be driven for real**: `ClickLandsOnTheCubesFaceTests` pairs a device
/// under a window that is already up and clicks a category, which is the click being refused by an app that was its
/// own clock a moment earlier.
@MainActor
final class PairingIsWhatTheAppFollowsTests: XCTestCase, @unchecked Sendable {
    private var database: TemporaryDatabase!
    private var settings: SettingStore!
    private var controller: SettingsWindowController!

    override func setUpWithError() throws {
        try super.setUpWithError()
        try MainActor.assumeIsolated {
            database = TemporaryDatabase()
            _ = try database.bootstrap()
            let connection = database.connection()
            settings = SettingStore(connection: connection)
            // A cube on record, which is what a launch that follows one has. Written before the controller is built,
            // so the window opens on a paired app exactly as it would in a launch.
            XCTAssertTrue(settings.write("paired", field: "paired", true))
            let store = settings!
            controller = SettingsWindowController(
                debugLog: nil,
                categories: CategoryStore(connection: connection),
                faces: FaceStore(connection: connection),
                settings: settings,
                isManualMode: { store.flag("paired", field: "paired") != true }
            )
        }
    }

    override func tearDown() {
        MainActor.assumeIsolated {
            controller?.stopTicking()
            controller = nil
            settings = nil
            database.remove()
        }
        super.tearDown()
    }

    private func descendants(of root: NSView) -> [NSView] {
        root.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    private func devicePane() throws -> DevicePane {
        try XCTUnwrap(controller.panes.tabViewItems.compactMap { $0.view as? DevicePane }.first)
    }

    /// What the Connection row is showing, which is the tab's own account of what this app is.
    private func connectionRow() throws -> String {
        try XCTUnwrap(
            descendants(of: devicePane())
                .first { $0.accessibilityIdentifier() == DevicePane.Identifier.connection }
                .flatMap { ($0 as? NSTextField)?.stringValue }
        )
    }

    func testAPairedAppDrawsTheCubeRatherThanItself() {
        // The precondition the rest of this leans on, stated rather than assumed.
        XCTAssertEqual(settings.flag("paired", field: "paired"), true)
        XCTAssertEqual(try? connectionRow(), "Disconnected", "a cube on record, with no link to it")
    }

    func testForgettingTheDeviceMakesTheAppItsOwnClockAtOnce() throws {
        // **The whole of the change, in one press.** No relaunch, and nothing told: the row is written, and the tab
        // draws what it now says because it went back and asked. The old wording here named a restart out loud --
        // "Device gone, restart to time by hand" -- which was the app admitting that being unpaired was not yet
        // enough to make it its own clock.
        let pane = try devicePane()

        pane.onForget?()

        XCTAssertEqual(settings.flag("paired", field: "paired"), false)
        XCTAssertEqual(try connectionRow(), "Manual mode, no device")
    }

    func testForgettingTellsWhateverOnlyRepaintsOnATick() throws {
        // The menu bar is the one surface that does not ask again on its own, and this is the funnel that reaches it.
        // Without it a device forgotten while nothing was being timed would leave the item drawn for an app that was
        // still following a cube, which is the exact staleness the switching used to be blamed for.
        var redraws = 0
        controller.onTimingChanged = { redraws += 1 }
        let pane = try devicePane()

        pane.onForget?()

        XCTAssertEqual(redraws, 1)
    }
}
