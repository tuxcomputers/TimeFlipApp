@testable import FacetApp

/// Colours to give a test category.
///
/// **Its own type rather than statics on `Colour`, because the component names are the same words.** A
/// `static let red` on `Colour` shadows the `red` component for the whole test target: the compiler stops finding
/// the instance member and every `colour.red` in an assertion fails to build.
///
/// **Fixtures, which is why they are here and not in `Sources/`.** Nothing in the app picks a colour by name; a
/// category's comes out of the `colour` table as a hex, and the only two the app names for itself are `Colour.white`
/// and `Colour.black`, which `DeviceFaceRules` falls back to. The values are the sRGB hexes of the AppKit constants
/// these call sites used to name, so an assertion on components still asserts on the numbers it did before.
enum SampleColour {
    static let red = Colour(red: 1, green: 0, blue: 0)
    static let green = Colour(red: 0, green: 1, blue: 0)
    static let blue = Colour(red: 0, green: 0, blue: 1)
    static let yellow = Colour(red: 1, green: 1, blue: 0)
    static let orange = Colour(red: 1, green: 0.5, blue: 0)
    static let brown = Colour(red: 0.6, green: 0.4, blue: 0.2)
    static let magenta = Colour(red: 1, green: 0, blue: 1)
}
