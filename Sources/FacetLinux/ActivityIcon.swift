import CGtk
import FacetCore
import Foundation

/// Loads a category's artwork from the bundled SVGs in `Resources/Icons`.
///
/// **The same files the Mac draws, reached through a symlinked directory.** `Sources/FacetLinux/Resources/Icons`
/// points at `Sources/FacetMac/Resources/Icons`, which is the arrangement the DDL already uses
/// (`Sources/FacetCore/Resources/Database` -> `database/`) and for the same reason: the artwork is shared and
/// neither platform owns it, while SwiftPM requires a target's resources to sit inside the target. A symlinked
/// *directory* is followed when the bundle is built; a symlinked file is not, which is measured and is why
/// `facet.svg` beside it is a copy.
///
/// **Provisional in one respect**, and it is named here rather than left to be noticed: the real directory is still
/// under `Sources/FacetMac`, so the AppKit target holds a file the GTK one needs. Moving it to a home of its own
/// belongs with the repository restructure, item 13 of `docs/linux-port.md`, because it touches both platforms'
/// resource declarations and only the Mac can compile its half.
///
/// **Drawn in the colour labels are drawn in**, which is `ActivityIcon`'s decision on the Mac as well: the artwork
/// is authored `stroke="black"`, and black on this platform's dark themes is a glyph nobody can see. The Mac gets
/// there by making the image a template and tinting it; there is no template here, so the stroke is substituted in
/// the SVG text before it is rendered -- the same textual substitution `colouredImage` already does for a category
/// colour, and for the same reason: it is the only way to reach inside an SVG without a parser.
enum ActivityIcon {
    /// What the artwork is authored with, and what gets replaced. A literal rather than a guess: `ic_admin.svg` and
    /// its forty-one siblings all open `<svg stroke="black"`, and `ActivityIconTests` on the Mac is what keeps that
    /// true.
    private static let authoredStroke = "stroke=\"black\""

    /// One icon as a `GtkImage`, or `nil` for artwork that is not there.
    ///
    /// **`nil` rather than a placeholder**, because what to draw instead is the row's decision: the Categories tab
    /// draws a "no icon" glyph in an empty cell, and a picker leaves the cell out. Answering with something here
    /// would take that choice away from both.
    static func image(named name: String, size: Int, colour: GdkRGBA) -> UnsafeMutablePointer<GtkWidget>? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let url = resolveURL(for: trimmed),
              let svg = try? String(contentsOf: url, encoding: .utf8)
        else {
            return nil
        }
        let recoloured = svg.replacingOccurrences(
            of: authoredStroke,
            with: "stroke=\"\(hex(colour))\""
        )
        guard let pixbuf = render(recoloured, size: size) else { return nil }
        let image = gtk_image_new_from_pixbuf(pixbuf)
        // The image holds its own reference now, so this one is given up -- a pixbuf per row leaked would be a
        // window that grows every time a list is read again, which is every edit.
        g_object_unref(UnsafeMutableRawPointer(pixbuf))
        return image
    }

    /// Renders SVG text at a size, through gdk-pixbuf's librsvg loader.
    ///
    /// **From a stream rather than a file**, because the text has been recoloured and there is no file holding it.
    /// `..._at_scale` is what makes the vector render at the size asked for instead of at its authored one: a 20pt
    /// cell drawn from a 65pt raster is the upscaled version of the same glyph.
    private static func render(_ svg: String, size: Int) -> OpaquePointer? {
        var data = Array(svg.utf8)
        // `OpaquePointer`, because `GdkPixbuf` is an incomplete struct in the headers and Swift imports a pointer to
        // one as exactly that. `GtkWidget` is a defined struct and so arrives typed, which is why the two read
        // differently in this file.
        return data.withUnsafeMutableBufferPointer { bytes -> OpaquePointer? in
            // `nil` as the destroy notify: the stream reads from this buffer and is finished with before
            // `withUnsafeMutableBufferPointer` returns, so nothing outlives the pointer.
            guard let stream = g_memory_input_stream_new_from_data(bytes.baseAddress, bytes.count, nil) else {
                return nil
            }
            defer { g_object_unref(stream) }
            var error: UnsafeMutablePointer<GError>?
            let pixbuf = gdk_pixbuf_new_from_stream_at_scale(
                stream, Int32(size), Int32(size), 1, nil, &error
            )
            if let error {
                // **Said rather than swallowed**, which `CLAUDE.md` is explicit about: artwork that silently fails
                // to render is a column that looks like it was never filled in.
                FileHandle.standardError.write(
                    Data("The icon could not be drawn: \(String(cString: error.pointee.message)).\n".utf8)
                )
                g_error_free(error)
                return nil
            }
            return pixbuf
        }
    }

    /// `#RRGGBB`, which is what an SVG attribute takes. Six digits rather than eight: the alpha is the widget's
    /// business and an SVG that carried one would be drawing its own opacity.
    private static func hex(_ colour: GdkRGBA) -> String {
        let channels = [colour.red, colour.green, colour.blue]
        return "#" + channels.map { String(format: "%02X", Int(($0 * 255).rounded())) }.joined()
    }

    /// **`Bundle.module` and nothing behind it**, which is where the two platforms differ: the Mac asks
    /// `Bundle.main` first, because Swift Bundler flattens its resources into the packaged app, and nothing does
    /// that here -- the bundle sits beside the binary, which is the same place `MenuBar` finds `facet.svg`.
    ///
    /// **The flat lookup is the one that answers, and that is measured** (2026-09-16, on this box): `.process` on a
    /// resource directory puts every file at the root of the bundle, so all 42 icons land beside `facet.svg` and
    /// `Icons/Activities` exists nowhere in it. Asking by subdirectory first found nothing and every row drew the
    /// no-icon glyph, which is a fault that announces itself as a design decision. The two subdirectory lookups stay
    /// behind it because they cost nothing and because the Mac's copy has them, and a packaging change that stopped
    /// flattening would otherwise break this quietly on one platform only.
    private static func resolveURL(for name: String) -> URL? {
        Bundle.module.url(forResource: name, withExtension: "svg")
            ?? Bundle.module.url(forResource: name, withExtension: "svg", subdirectory: "Icons/Activities")
            ?? Bundle.module.url(forResource: name, withExtension: "svg", subdirectory: "Icons/UI")
    }
}
