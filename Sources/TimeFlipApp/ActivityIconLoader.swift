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
    }
}
