import AppKit

/// Which face the cube is resting on, and what colours that face is drawn in.
///
/// Pure, the way `BatteryRules` is pure: what a byte off the radio means, and what a face comes out looking like,
/// with no view, no database and no peripheral in sight. The reads that turn a face into a category happen at the
/// point of use (see `SettingsWindowController.categoryOnFace`); what arrives here is the answer, not the question.
enum DeviceFaceRules {
    /// The faces a cube reports.
    ///
    /// The ceiling is `ManualFace.highestDeviceFace` rather than a `12` written again, because it is the same fact
    /// seen from the other side: nothing above 12 ever comes from a device, which is exactly what leaves the numbers
    /// above it free for the app's own faces.
    static let reported = 1...ManualFace.highestDeviceFace

    /// The face a value on `faces` names, or `nil` when it names none.
    ///
    /// **One byte, and everything past it is somebody else's.** The characteristic is declared as a single byte in
    /// `docs/TimeFlip2 BLE Protocol v4.3.md`, and the values this cube has actually sent are `02` and `08`
    /// (`docs/timeflip2-firmware-evidence.sqlite`, rows 14527 and the flips logged beside it), so the first byte is
    /// read and the rest ignored rather than parsed into a number nobody has seen.
    ///
    /// **A face outside 1 to 12 is refused rather than clamped.** The archive treated the cube's byte as the face id
    /// directly, and this keeps that -- but a cube reporting `0`, or a value from a characteristic that turned out
    /// not to be this one, is not a face to draw, and rounding it into range would put a category on screen for a
    /// face the cube never named.
    ///
    /// **Whether the numbering is the app's numbering is not settled on hardware.** Only two of the twelve have ever
    /// been seen, so that the cube's `02` is `face_id` 2 is the archive's assumption carried forward rather than a
    /// measurement. Flipping through every side with the log on is what would settle it.
    static func face(from value: Data?) -> Int? {
        guard let byte = value?.first else { return nil }
        let face = Int(byte)
        return reported.contains(face) ? face : nil
    }

    /// The colour the device's body is drawn in for a face: its category's colour, or **white** when there is none.
    ///
    /// **White covers both** a face holding no category and a category with no colour of its own, because on the body
    /// of the device the two mean the same thing: nothing is lit, and an unlit cube is white plastic. The archive
    /// answered this question three different ways on purpose -- an icon falls back to the ordinary label colour so it
    /// stays legible, the LED falls back to dark because that is off on the hardware, and the drawn body falls back to
    /// white -- and this is that one, copied with its reasoning.
    static func bodyColour(for category: CategoryRecord?) -> NSColor {
        category?.colour ?? .white
    }

    /// The colour the device's inner lines and its centre icon are drawn in: white where the body's colour is dark
    /// enough to swallow black, black otherwise.
    ///
    /// **Which colours flip is a column, not a rule in code**: `colour.white_lines` in `database/005_colour.sql`,
    /// carried on `CategoryRecord`, so the choice is retuned by editing a row. The same flag the category lists and
    /// the Report tab already draw their icons from, asked here for the same reason.
    ///
    /// The device's outer outline is **not** this colour. It stays black whatever the face is lit in, so the shape
    /// still reads against the window behind it -- which is why the artwork authors its outline separately from its
    /// inner lines (see `ic_facet.svg`).
    static func lineColour(for category: CategoryRecord?) -> NSColor {
        (category?.usesWhiteLines ?? false) ? .white : .black
    }
}
