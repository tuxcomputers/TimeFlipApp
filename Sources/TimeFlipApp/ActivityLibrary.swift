import SwiftUI

/// One cell of the Categories tab's icon grid: the `icon` table's id paired with the asset name to
/// draw and a human-readable label.
///
/// There used to be a second option type, `ActivityIconOption`, built from a hardcoded list of asset
/// names for the blob-era Faces grid. It worked in names alone and had no `icon_id` to write back,
/// which is why it could not survive the move to categories; it went with the list.
struct CategoryIconOption: Identifiable {
    let iconId: Int
    let name: String
    let iconName: String

    var id: Int { iconId }
}

struct ActivityColorOption: Identifiable {
    let colourId: Int
    let name: String
    let color: Color
    /// The same colour as `color`, kept in the form the device wants. Held rather than re-derived
    /// from `color` because that round trip goes through `NSColor` and a colour-space conversion,
    /// which can drift a channel -- and this is the value written to the LED (BLE `0x11`).
    let components: ColorComponents
    /// `true` when the device drawn in this colour needs white inner lines and a white icon --
    /// straight from the `colour` row (see `ColourRecord.usesWhiteLines`).
    let usesWhiteLines: Bool

    var id: String { name }
}

enum ActivityLibrary {
    /// The Categories tab's icon-grid options, built from the `icon` reference table
    /// (`AppDataStore.loadIcons`). Skips `icon_id` 0, whose `None` name is a sentinel rather than an
    /// asset: the grid clears an icon by re-clicking the selected one, so it needs no cell of its own
    /// for "none".
    ///
    /// **Every other row is offered, and the table is the only say in what exists.** A hardcoded
    /// `validIconNames` set used to filter this, built from a 42-name Swift array that duplicated the
    /// table -- so adding an icon meant editing the DDL *and* the array, and a row missing from the
    /// array vanished from the grid with nothing said. The two happened to agree exactly (checked:
    /// zero names in either that the other lacked), which is the only reason it never bit.
    ///
    /// What replaces the gate is a complaint rather than a filter: a row naming an asset that will not
    /// load is reported by `reportUnresolvableIcons` at launch, and still offered. Drawing it falls
    /// back to a placeholder glyph, so the failure is visible in the grid instead of the row silently
    /// not existing.
    static func iconOptions(from icons: [IconRecord]) -> [CategoryIconOption] {
        icons.compactMap { record in
            guard record.id >= 1 else { return nil }
            return CategoryIconOption(iconId: record.id, name: displayName(for: record.name), iconName: record.name)
        }
    }

    /// Logs any offered icon whose SVG cannot be found in the bundle, once at launch.
    ///
    /// The check the deleted `validIconNames` gate was standing in for, done against the bundle
    /// itself rather than against a second list in Swift -- which could only ever say whether a name
    /// matched *the array*, not whether the artwork was actually there. Reporting instead of
    /// filtering is the point: a row that cannot draw is a packaging mistake to fix, not a row to
    /// pretend is absent.
    static func reportUnresolvableIcons(_ options: [CategoryIconOption]) {
        let missing = options.filter { ActivityIconLoader.image(named: $0.iconName, pointSize: 16) == nil }
        guard !missing.isEmpty else { return }
        DeveloperMode.debugPrint(
            .icons,
            "icon rows with no bundled asset: \(missing.map { "\($0.iconId)=\($0.iconName)" }.joined(separator: " ")) -- offered anyway, and will draw as a placeholder"
        )
    }

    /// The face colour-picker options, built from the `colour` reference table
    /// (`AppDataStore.loadColours`). Each option's swatch is the row's `device_hex`; rows without
    /// one (e.g. the `None` colour) are skipped.
    static func colorOptions(from colours: [ColourRecord]) -> [ActivityColorOption] {
        colours.compactMap { record in
            guard let hex = record.deviceHex, let components = ColorComponents(hex: hex) else {
                return nil
            }
            return ActivityColorOption(
                colourId: record.id,
                name: record.name,
                color: components.color,
                components: components,
                usesWhiteLines: record.usesWhiteLines
            )
        }
    }

    /// Tidies a typed category name: leading and trailing whitespace removed, and any internal run
    /// of whitespace collapsed to a single space. Deliberately does **not** filter characters: a
    /// ticket-style name like `ACME-123` has to survive intact. The face-name sanitizer that did
    /// filter (and would have made that `ACME123`) went with the UserDefaults blob it policed.
    ///
    /// Collapsing matters beyond tidiness: it happens before the already-exists check, so
    /// `"Client  work"` is recognised as the `"Client work"` that already exists rather than
    /// quietly becoming a second category that looks identical in a list.
    static func normalizeCategoryName(_ value: String) -> String {
        value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func displayName(for iconName: String) -> String {
        let trimmed = iconName.replacingOccurrences(of: "ic_", with: "")
        let parts = trimmed.split(separator: "_").map { part in
            let lower = part.lowercased()
            return lower.prefix(1).uppercased() + lower.dropFirst()
        }
        return parts.joined(separator: " ")
    }

}
