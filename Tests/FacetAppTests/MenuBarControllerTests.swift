@testable import FacetApp
import AppKit
import XCTest

/// Covers the dropdown -- what is in it, and how the Pause item reads and behaves for each timing state -- and the
/// order of the status item's own line.
///
/// Both are checked without calling `start()`, which would put a real status item in the menu bar of whoever is
/// running the tests. What the line *says* is `StatusItemTitle`'s to decide and is tested there; this covers the
/// composition, which is where the order lives.
///
/// Worth testing at all because the previous app's equivalent was three expressions inside a method that
/// built `NSMenuItem`s, out of reach of any test -- and that is how the dropdown came to disagree with the
/// status item about pausing, with nothing failing.
@MainActor
final class MenuBarControllerTests: XCTestCase {
    private var reading: TimingReadout.Reading = .idle
    private var state: TimingState {
        get { reading.state }
        set { reading = TimingReadout.Reading(category: reading.category, state: newValue, seconds: reading.seconds) }
    }
    private var toggles = 0

    /// Held for the length of the test, because an item's `target` is **weak**: a controller nobody keeps is
    /// deallocated the moment it is built, and then choosing an item reaches nobody, silently.
    ///
    /// The menu's *state* no longer depends on this -- `refresh` is called directly rather than through a weak
    /// delegate -- but the action still does, which is the same reason `main.swift` keeps the controller in a
    /// binding.
    private var kept: MenuBarController?

    override func tearDown() {
        kept = nil
        super.tearDown()
    }

    private func controller(badge: DatabaseBadge? = nil, showingSeconds: Bool = true) -> MenuBarController {
        let controller = MenuBarController(
            databaseBadge: badge,
            debugLog: nil,
            openSettings: {},
            timing: { self.reading },
            showingSeconds: { showingSeconds },
            togglePause: { self.toggles += 1 }
        )
        kept = controller
        return controller
    }

    private func menu() -> NSMenu {
        let controller = controller()
        let menu = controller.makeMenu()
        // What the controller does as it presents the menu, which is when the Pause item is named and enabled.
        controller.refresh(menu)
        return menu
    }

    private func pauseItem(in menu: NSMenu) -> NSMenuItem? {
        menu.items.first { $0.identifier?.rawValue == MenuBarController.Identifier.togglePause }
    }

    // MARK: - what is in it

    func testTheItemsAndTheirOrder() {
        let items = menu().items

        XCTAssertEqual(
            items.map { $0.isSeparatorItem ? "---" : ($0.identifier?.rawValue ?? "?") },
            ["open-settings", "toggle-pause", "---", "quit-app"],
            "Pause sits under Settings, and Quit stays behind a separator"
        )
    }

    func testEveryItemIsNamedForAScript() {
        for item in menu().items where !item.isSeparatorItem {
            XCTAssertNotNil(item.identifier?.rawValue, "\(item.title) needs an identifier")
            XCTAssertEqual(item.accessibilityIdentifier(), item.identifier?.rawValue)
        }
    }

    // MARK: - what Pause says

    func testWithNothingBeingTimedItReadsPauseAndCannotBeChosen() {
        state = .idle

        let pause = pauseItem(in: menu())

        // "Pause" rather than "Resume": the item is dead either way, and a dead item claiming there is
        // something to resume is worse than one claiming there is something to pause.
        XCTAssertEqual(pause?.title, "Pause")
        XCTAssertEqual(pause?.isEnabled, false)
    }

    func testWhileRunningItOffersToPause() {
        state = .running

        let pause = pauseItem(in: menu())

        // A menu item says what clicking does, which is the opposite of the glyph beside it: play showing
        // means recording, and this reads "Pause" at the same moment.
        XCTAssertEqual(pause?.title, "Pause")
        XCTAssertEqual(pause?.isEnabled, true)
    }

    func testWhileStoppedItOffersToResume() {
        state = .paused

        let pause = pauseItem(in: menu())

        XCTAssertEqual(pause?.title, "Resume")
        XCTAssertEqual(pause?.isEnabled, true)
    }

    func testItIsRenamedEveryTimeTheMenuOpens() {
        let controller = controller()
        let menu = controller.makeMenu()

        state = .running
        controller.refresh(menu)
        XCTAssertEqual(pauseItem(in: menu)?.title, "Pause")

        state = .paused
        controller.refresh(menu)

        // Asked as the menu opens rather than pushed when the clock changes: a menu that never remembers
        // cannot be stale, and nothing else has to know the menu exists.
        XCTAssertEqual(pauseItem(in: menu)?.title, "Resume")
    }

    func testTheMenuDoesNotLetAppKitDecideWhatIsEnabled() {
        // Left on, AppKit enables an item whose action can be found -- which is always -- and overwrites
        // what the delegate just set.
        XCTAssertFalse(menu().autoenablesItems)
    }

    // MARK: - what choosing it does

    // MARK: - the line the item draws

    /// What an image in a line of text comes back as when the string is read as plain text.
    private let attachment = "\u{FFFC}"

    private func title(_ controller: MenuBarController) -> NSAttributedString {
        controller.makeTitle(
            StatusItemTitle.make(
                appLabel: "Facet",
                badgeDescription: nil,
                reading: reading,
                showingSeconds: true
            )
        )
    }

    private func line(_ controller: MenuBarController) -> String {
        title(controller).string
    }

    /// The colour a stretch of the drawn line carries.
    private func colour(of substring: String, in title: NSAttributedString) -> NSColor? {
        let range = (title.string as NSString).range(of: substring)
        guard range.location != NSNotFound else { return nil }
        return title.attribute(.foregroundColor, at: range.location, effectiveRange: nil) as? NSColor
    }

    func testTheOrderIsBadgeIconCategoryGlyphThenTime() {
        reading = TimingReadout.Reading(
            category: CategoryRecord(
                id: 2, name: "Meeting", iconName: "ic_calls", colourID: 0, colour: nil, usesWhiteLines: false, dailyLimitMinutes: 0, isActive: true
            ),
            state: .running,
            seconds: 30
        )

        // The badge is first because it qualifies everything to its right, and the icon is inside the line rather
        // than the button's own image, which would draw it to the badge's left.
        XCTAssertEqual(
            line(controller(badge: .forEnvironment(.test))),
            "TEST \(attachment) Meeting \(attachment) 0:00:30"
        )
    }

    func testWithNothingBeingTimedItIsTheAppsNameAlone() {
        reading = .idle

        XCTAssertEqual(line(controller(badge: .forEnvironment(.test))), "TEST Facet")
    }

    func testWithoutTheDevFlagThereIsNoBadgeInTheLine() {
        reading = .idle

        // A shipped copy only ever has the real database, so a permanent "PROD" tag would take up menu bar space
        // answering something nobody asked.
        XCTAssertEqual(line(controller()), "Facet")
    }

    func testTheBadgeKeepsItsOwnColourWhileTheSessionIsGreen() {
        reading = TimingReadout.Reading(
            category: CategoryRecord(
                id: 2, name: "Meeting", iconName: "ic_calls", colourID: 0, colour: nil, usesWhiteLines: false, dailyLimitMinutes: 0, isActive: true
            ),
            state: .running,
            seconds: 30
        )

        let title = title(controller(badge: .forEnvironment(.test)))

        // Two separate things being said: which database this launch writes to, and what the app is doing. A green
        // "TEST" would lose the warning the red is there to carry.
        XCTAssertEqual(colour(of: "TEST", in: title), .systemRed)
        XCTAssertEqual(colour(of: "Meeting", in: title), .systemGreen)
        XCTAssertEqual(colour(of: "0:00:30", in: title), .systemGreen)
    }

    func testWithNothingBeingTimedTheAppsNameIsNotGreen() {
        reading = .idle

        XCTAssertEqual(colour(of: "Facet", in: title(controller())), .labelColor)
    }

    func testACategoryWithNoIconDrawsOneAttachmentRatherThanTwo() {
        reading = TimingReadout.Reading(
            category: CategoryRecord(
                id: 2, name: "Meeting", iconName: nil, colourID: 0, colour: nil, usesWhiteLines: false, dailyLimitMinutes: 0, isActive: true
            ),
            state: .paused,
            seconds: 30
        )

        XCTAssertEqual(line(controller()), "Meeting \(attachment) 0:00:30", "the glyph, and no artwork before the name")
    }

    // MARK: - what choosing it does

    func testChoosingItGoesToTheOneTogglePath() throws {
        state = .running
        let menu = menu()
        let pause = try XCTUnwrap(pauseItem(in: menu))

        // `NSApplication.shared` rather than `NSApp`: the latter is an implicitly unwrapped global that is
        // nil in a test bundle until the application object has been made, and reading it crashes the run.
        NSApplication.shared.sendAction(try XCTUnwrap(pause.action), to: pause.target, from: pause)

        XCTAssertEqual(toggles, 1, "the same closure the Timing column's control ends in")
    }
}
