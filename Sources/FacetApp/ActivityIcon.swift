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
