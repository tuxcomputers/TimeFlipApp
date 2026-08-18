import AppKit

/// Loads a category's artwork from the bundled SVGs in `Resources/Icons`.
///
/// Returned as a **template** image, so whatever draws it decides the colour. That matters here because
/// the same glyph is drawn black on a light category colour and white on a dark one.
enum ActivityIcon {
    static func image(named name: String, pointSize: CGFloat) -> NSImage? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let url = resolveURL(for: trimmed),
              let representation = NSImageRep(contentsOf: url)
        else {
            return nil
        }
        let image = NSImage(size: NSSize(width: pointSize, height: pointSize))
        image.addRepresentation(representation)
        image.isTemplate = true
        return image
    }

    /// Renders artwork in `fill` instead of as a template, so it keeps its own line work while its filled areas take
    /// the colour they are given. `image(named:pointSize:)` cannot do this: a template keeps only the alpha and floods
    /// the whole glyph with one tint, which would swallow the lines and the ring along with them.
    ///
    /// `ink` recolours only the artwork's **inner** lines, for artwork that authors them separately from its outline
    /// (see `ic_facet.svg`, whose outline is authored black and stays that way, and whose ring is authored red and
    /// stays that too). `nil` leaves every line as drawn.
    ///
    /// **Both colours are substituted textually**, replacing the placeholders the artwork is authored with, which is
    /// the archive's approach copied rather than reworked: it is the only way to reach inside an SVG without a parser,
    /// and the placeholders are deliberately colours nobody would choose, so a substitution that ever stops matching
    /// shows up on screen as magenta rather than passing for a real answer. `ActivityIconTests` asserts the bundled
    /// artwork still carries them, since the substitution is a string match and a drawing tool is free to rewrite an
    /// attribute into a `style` on any save.
    ///
    /// Replacements are always 6-digit hex. The archive measured why, and it holds today: AppKit's SVG rendering
    /// ignores 8-digit `#RRGGBBAA` and silently falls back to opaque black.
    static func colouredImage(named name: String, pointSize: CGFloat, fill: NSColor, ink: NSColor? = nil) -> NSImage? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let url = resolveURL(for: trimmed),
              let svg = try? String(contentsOf: url, encoding: .utf8),
              let hex = hexString(for: fill) else { return nil }
        var recoloured = svg.replacingOccurrences(of: Placeholder.fill, with: "fill=\"\(hex)\"")
        if let ink, let inkHex = hexString(for: ink) {
            recoloured = recoloured.replacingOccurrences(of: Placeholder.ink, with: "stroke=\"\(inkHex)\"")
        }
        guard let data = recoloured.data(using: .utf8), let image = NSImage(data: data) else { return nil }
        // A vector re-renders at whatever size it is drawn, so this only has to be generous enough that nothing
        // downstream is ever upscaling a raster that was made too small.
        image.size = NSSize(width: pointSize, height: pointSize)
        return image
    }

    /// What the recolourable artwork in `Resources/Icons` is authored with. Neither is a colour a designer would
    /// reach for, which is the point: they are meant to be replaced, and to be unmistakable when they are not.
    enum Placeholder {
        static let fill = "fill=\"#ff8b97a5\""
        static let ink = "stroke=\"#ff00ff\""
    }

    private static func hexString(for colour: NSColor) -> String? {
        guard let rgb = colour.usingColorSpace(.sRGB) else { return nil }
        let channels = [rgb.redComponent, rgb.greenComponent, rgb.blueComponent]
        return "#" + channels.map { String(format: "%02X", Int(($0 * 255).rounded())) }.joined()
    }

    /// Kept verbatim from the previous app, because the order of these four lookups is a finding rather
    /// than a preference:
    ///
    /// Swift Bundler flattens this target's SwiftPM resources directly into the packaged app's
    /// `Contents/Resources` (unlike third-party dependency resource bundles, which it leaves wrapped) --
    /// so `Bundle.module`'s generated accessor, which expects a wrapped `FacetApp_FacetApp.bundle`
    /// inside `Bundle.main`, cannot find them there and falls back to an absolute build-directory path
    /// baked in at compile time. That path only happens to work on the exact machine and checkout that
    /// built it, breaking for anyone else or after `.build` is cleaned. So `Bundle.main` is asked first,
    /// matching the packaged app's real layout, with `Bundle.module` behind it for `swift run`/`swift
    /// test`, where resources sit next to the debug binary instead of inside an app bundle.
    private static func resolveURL(for name: String) -> URL? {
        Bundle.main.url(forResource: name, withExtension: "svg")
            ?? Bundle.module.url(forResource: name, withExtension: "svg")
            ?? Bundle.module.url(forResource: name, withExtension: "svg", subdirectory: "Icons/Activities")
            ?? Bundle.module.url(forResource: name, withExtension: "svg", subdirectory: "Icons/UI")
    }
}
