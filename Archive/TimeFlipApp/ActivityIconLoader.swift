import AppKit

enum ActivityIconLoader {
    static func image(named name: String, pointSize: CGFloat) -> NSImage? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let url = resolveURL(for: trimmed) else {
            return nil
        }
        guard let rep = NSImageRep(contentsOf: url) else {
            return nil
        }
        let image = NSImage(size: NSSize(width: pointSize, height: pointSize))
        image.addRepresentation(rep)
        image.isTemplate = true
        return image
    }

    /// Renders an SVG in `fill` instead of as a template image, so the artwork keeps its own line
    /// work while the filled areas take the supplied colour. `image(named:pointSize:)` can't do
    /// this: template rendering keeps only the alpha channel and floods the whole glyph with one
    /// tint, which would swallow the lines.
    ///
    /// `ink` recolours only the artwork's *inner* lines, for artwork that separates them from its
    /// outline (see `ic_timeflip2`, whose outline is authored black and stays that way). Passing
    /// `nil` leaves every line as authored.
    ///
    /// Both colours are substituted textually, replacing the placeholders the artwork is authored
    /// with. Note AppKit's SVG renderer ignores 8-digit `#RRGGBBAA` and silently falls back to
    /// black, so replacements are always written as 6-digit hex.
    static func colouredImage(
        named name: String,
        pointSize: CGFloat,
        fill: NSColor,
        ink: NSColor? = nil
    ) -> NSImage? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let url = resolveURL(for: trimmed),
              let svg = try? String(contentsOf: url, encoding: .utf8),
              let hex = hexString(for: fill) else { return nil }
        var recoloured = svg.replacingOccurrences(of: placeholderFill, with: "fill=\"\(hex)\"")
        if let ink, let inkHex = hexString(for: ink) {
            recoloured = recoloured.replacingOccurrences(
                of: placeholderInk,
                with: "stroke=\"\(inkHex)\""
            )
        }
        guard let data = recoloured.data(using: .utf8),
              let image = NSImage(data: data) else { return nil }
        image.size = NSSize(width: pointSize, height: pointSize)
        return image
    }

    /// The fill the recolourable artwork is authored with -- see `Resources/Icons/UI`.
    private static let placeholderFill = "fill=\"#ff8b97a5\""

    /// The inner-line stroke the recolourable artwork is authored with. Deliberately a colour
    /// nothing would choose, so a substitution that ever stops matching shows up on screen rather
    /// than passing for the real thing.
    private static let placeholderInk = "stroke=\"#ff00ff\""

    private static func hexString(for colour: NSColor) -> String? {
        guard let rgb = colour.usingColorSpace(.sRGB) else { return nil }
        let channels = [rgb.redComponent, rgb.greenComponent, rgb.blueComponent]
        return "#" + channels.map { String(format: "%02X", Int(($0 * 255).rounded())) }.joined()
    }

    /// Swift Bundler flattens this target's SwiftPM resources directly into the packaged app's
    /// `Contents/Resources` (unlike third-party dependency resource bundles, which it leaves
    /// wrapped) — so `Bundle.module`'s generated accessor, which expects a wrapped
    /// `TimeFlipApp_TimeFlipApp.bundle` inside `Bundle.main`, can't find them there and falls
    /// back to an absolute build-directory path baked in at compile time. That path only happens
    /// to work on the exact machine/checkout that built it, breaking for anyone else (or after
    /// `.build` is cleaned). Check `Bundle.main` first, matching the packaged app's real layout,
    /// and fall back to `Bundle.module` for `swift run`/`swift test`, where resources sit next to
    /// the debug binary instead of inside an app bundle.
    private static func resolveURL(for name: String) -> URL? {
        Bundle.main.url(forResource: name, withExtension: "svg")
            ?? Bundle.module.url(forResource: name, withExtension: "svg")
            ?? Bundle.module.url(forResource: name, withExtension: "svg", subdirectory: "Icons/Activities")
            ?? Bundle.module.url(forResource: name, withExtension: "svg", subdirectory: "Icons/UI")
    }
}
