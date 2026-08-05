import SwiftUI
@testable import TimeFlipApp
import XCTest

/// What a face resolves to for display: the menu bar's `Activity`, the three on-screen colours, and
/// the LED triple. All five ask the same question -- "which `colour`/`icon` row does this face's
/// category point at?" -- and each answers a miss differently on purpose, which is the part worth
/// pinning down. None of it had coverage before the lookups were indexed by id.
@MainActor
final class FaceCategoryResolutionTests: XCTestCase {
    private enum Fixture {
        /// A dark colour, so `usesWhiteLines` is on.
        static let navyID = 7
        static let navyHex = "#001f3f"
        /// A light one, lines stay black.
        static let lemonID = 8
        static let lemonHex = "#ffff66"
        static let meetingIconID = 3
        static let meetingIconName = "ic_meeting"

        static let colours: [ActivityColorOption] = [
            ActivityColorOption(
                colourId: navyID,
                name: "Navy",
                color: ColorComponents(hex: navyHex)!.color,
                components: ColorComponents(hex: navyHex)!,
                usesWhiteLines: true
            ),
            ActivityColorOption(
                colourId: lemonID,
                name: "Lemon",
                color: ColorComponents(hex: lemonHex)!.color,
                components: ColorComponents(hex: lemonHex)!,
                usesWhiteLines: false
            )
        ]

        static let icons: [CategoryIconOption] = [
            CategoryIconOption(iconId: meetingIconID, name: "Meeting", iconName: meetingIconName)
        ]
    }

    /// - Parameter faces: face id → the category it is assigned.
    private func makeState(faces: [UInt8: CategoryRecord]) -> AppState {
        AppState(
            googleClientSecretStore: InMemoryGoogleClientSecretStore(),
            devicePasswordStore: InMemoryDevicePasswordStore(),
            autoPauseMinutes: 0,
            ledBrightnessPercent: 50,
            blinkIntervalSeconds: 15,
            doubleTapParameters: .default,
            isDoubleTapEnabled: true,
            colourOptions: Fixture.colours,
            iconOptions: Fixture.icons,
            faceCategories: faces
        )
    }

    private func category(
        id: Int = 2,
        name: String = "Meeting",
        iconID: Int = Fixture.meetingIconID,
        colourID: Int = Fixture.navyID,
        dailyLimitMinutes: Int = 60
    ) -> CategoryRecord {
        CategoryRecord(
            id: id,
            name: name,
            iconID: iconID,
            colourID: colourID,
            isActive: true,
            dailyLimitMinutes: dailyLimitMinutes
        )
    }

    // MARK: - categoryActivity

    func testResolvesEveryFieldTheMenuBarDraws() {
        let state = makeState(faces: [2: category()])
        let activity = state.categoryActivity(for: 2)

        XCTAssertEqual(activity?.categoryID, 2, "the key the day's total is looked up by")
        XCTAssertEqual(activity?.name, "Meeting")
        XCTAssertEqual(activity?.iconName, Fixture.meetingIconName, "icon_id resolved to its asset name")
        XCTAssertEqual(activity?.limitMinutes, 60)
    }

    func testAFaceWithNoCategoryResolvesToNothing() {
        let state = makeState(faces: [2: category()])
        XCTAssertNil(state.categoryActivity(for: 5), "face 5 has no category, so there is nothing to draw for it")
    }

    /// `icon_id` `0` is the `None` sentinel and never enters the palette, and neither does a row whose
    /// asset isn't bundled. Both arrive here as a miss, which has to mean "draw no icon" rather than
    /// failing to resolve the category at all.
    func testAnIconIDOutsideThePaletteLeavesTheNameButNoIcon() {
        let state = makeState(faces: [2: category(iconID: 0)])
        let activity = state.categoryActivity(for: 2)

        XCTAssertEqual(activity?.name, "Meeting", "the category still resolves")
        XCTAssertNil(activity?.iconName, "it just has no icon to draw")
    }

    /// `daily_limit` carries no `CHECK`, so a hand-edited row can hold a negative even though
    /// `updateCategoryDailyLimit` clamps what it writes. `0` means "no limit", and a negative has to
    /// land there rather than making every duration instantly over budget.
    func testANegativeStoredLimitClampsToNoLimit() {
        let state = makeState(faces: [2: category(dailyLimitMinutes: -30)])
        XCTAssertEqual(state.categoryActivity(for: 2)?.limitMinutes, 0)
    }

    /// The overload taking the dictionary is what a Combine sink uses, because `@Published` publishes
    /// in `willSet` and the property still holds the old value while the subscriber runs.
    func testTheExplicitDictionaryOverloadIsUsedInsteadOfTheStoredProperty() {
        let state = makeState(faces: [2: category(name: "Stale")])
        let incoming = [UInt8(2): category(name: "Fresh")]

        XCTAssertEqual(state.categoryActivity(for: 2)?.name, "Stale", "reading the property gives what is stored")
        XCTAssertEqual(
            state.categoryActivity(for: 2, in: incoming)?.name, "Fresh",
            "and passing the value in is what lets a sink use the one it was handed"
        )
    }

    // MARK: - The three on-screen colours, which differ only in what a miss means

    func testAResolvedColourIsTheSameColourEverywhere() {
        let state = makeState(faces: [2: category(colourID: Fixture.lemonID)])
        let expected = ColorComponents(hex: Fixture.lemonHex)!.color

        XCTAssertEqual(state.faceCategoryColour(for: 2), expected)
        XCTAssertEqual(state.deviceBodyColour(for: 2), expected)
        XCTAssertEqual(state.deviceLineColour(for: 2), .black, "Lemon is light, so the lines stay black")
    }

    func testDarkColoursTakeWhiteLines() {
        let state = makeState(faces: [2: category(colourID: Fixture.navyID)])
        XCTAssertEqual(state.deviceLineColour(for: 2), .white, "straight off the colour row's white_lines flag")
    }

    /// A category whose `colour_id` is `0` (`None`) has no `device_hex`, so it is absent from the
    /// palette -- the same miss as a face with no category at all. Each of the three renders it
    /// differently, and deliberately: an icon stays legible, the drawn device is unlit plastic, and
    /// black lines are the default.
    func testEachDrawingHelperHasItsOwnAnswerForNoColour() {
        let noColour = makeState(faces: [2: category(colourID: 0)])
        let noCategory = makeState(faces: [:])

        for (label, state) in [("colour_id 0", noColour), ("no category", noCategory)] {
            XCTAssertEqual(state.faceCategoryColour(for: 2), .primary, "\(label): an icon falls back to the foreground colour")
            XCTAssertEqual(state.deviceBodyColour(for: 2), .white, "\(label): an unlit device is white plastic")
            XCTAssertEqual(state.deviceLineColour(for: 2), .black, "\(label): lines default to black")
        }
    }

    // MARK: - faceLEDColours

    func testEveryFaceGetsAnLEDValueAndAMissMeansOff() {
        let state = makeState(faces: [:])
        let categories: [UInt8: CategoryRecord] = [
            2: category(colourID: Fixture.navyID),
            8: category(colourID: Fixture.lemonID),
            // In the palette's terms this is a miss, and the LED has to be told to go dark rather
            // than being left lit with whatever it had.
            5: category(colourID: 0)
        ]

        let resolved = state.faceLEDColours(in: categories)

        XCTAssertEqual(
            Set(resolved.keys), Set(TimeFlipConstants.faceIDs),
            "all twelve faces are written, so none is left showing a stale colour"
        )
        XCTAssertEqual(resolved[2], ColorComponents(hex: Fixture.navyHex))
        XCTAssertEqual(resolved[8], ColorComponents(hex: Fixture.lemonHex))
        XCTAssertEqual(resolved[5], .off, "a category with no colour means the LED off, not unchanged")
        XCTAssertEqual(resolved[11], .off, "and so does a face with no category")
    }
}
