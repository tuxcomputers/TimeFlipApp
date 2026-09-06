import Foundation

/// A colour as the palette holds it: four sRGB components, fixed.
///
/// **sRGB, and only sRGB.** The same three numbers name different colours in different spaces, and these are the
/// values a cube is eventually told to light its LED with (`database/005_colour.sql` stores them as hexes, and
/// `FaceColourRules` puts them on the wire). There is no space to convert from, so there is no conversion that can
/// fail.
///
/// **Fixed, so it is the wrong type for anything that has to resolve as it draws.** A menu bar line tints from the
/// wallpaper rather than from the appearance setting, so the status item's colours are `NSColor` semantic ones
/// (`StatusItemTitle.colour` says why) and stay that way. What belongs here is a colour somebody picked out of the
/// table: a category's, a face's, a swatch's.
///
/// Components are `0...1` and are not clamped on the way in. `nsColor` is how the UI draws one.
package struct Colour: Equatable {
    package let red: Double
    package let green: Double
    package let blue: Double
    package let alpha: Double

    init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    /// Parses `"#rrggbb"` (or `"rrggbb"`) into an opaque colour. `nil` for anything that is not exactly six hex
    /// digits, which includes the None colour's `NULL` hex.
    init?(hex: String) {
        var digits = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if digits.hasPrefix("#") { digits.removeFirst() }
        guard digits.count == 6, let rgb = UInt32(digits, radix: 16) else { return nil }
        self.init(
            red: Double((rgb >> 16) & 0xFF) / 255,
            green: Double((rgb >> 8) & 0xFF) / 255,
            blue: Double(rgb & 0xFF) / 255
        )
    }

    static let white = Colour(red: 1, green: 1, blue: 1)
    static let black = Colour(red: 0, green: 0, blue: 0)
}
