import SwiftUI

struct FacetMapping: Identifiable {
    let facetID: UInt8
    var name: String
    var iconName: String

    var id: UInt8 { facetID }

    var isAssigned: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var displayName: String {
        isAssigned ? name : "Unassigned"
    }
}

struct ActivityIconOption: Identifiable {
    let name: String
    let iconName: String

    var id: String { iconName }
}

/// One cell of the Categories tab's icon grid: the `icon` table's id paired with the asset name
/// to draw and a human-readable label. Distinct from `ActivityIconOption`, which the Faces grid
/// uses -- that one works in asset names alone and has no `icon_id` to write back.
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
    private static let allowedNameCharacters = CharacterSet.alphanumerics
        .union(.whitespaces)
        .union(CharacterSet(charactersIn: "?!"))

    static let iconNames: [String] = [
        "ic_admin",
        "ic_agile",
        "ic_brainstorming",
        "ic_break",
        "ic_bugs",
        "ic_calls",
        "ic_camera",
        "ic_chat",
        "ic_client",
        "ic_code",
        "ic_consult",
        "ic_design",
        "ic_document",
        "ic_edit",
        "ic_emails",
        "ic_facebook",
        "ic_fitness",
        "ic_games",
        "ic_internet",
        "ic_instagram",
        "ic_logistics",
        "ic_marketing",
        "ic_meeting",
        "ic_media",
        "ic_money",
        "ic_music",
        "ic_office",
        "ic_presentation",
        "ic_project",
        "ic_quotation",
        "ic_reading",
        "ic_report",
        "ic_shopping",
        "ic_studying",
        "ic_support",
        "ic_test",
        "ic_tv",
        "ic_twitter",
        "ic_urgent",
        "ic_ux",
        "ic_write",
        "ic_you_tube"
    ]

    static let iconOptions: [ActivityIconOption] = iconNames.map {
        ActivityIconOption(name: displayName(for: $0), iconName: $0)
    }

    /// The Categories tab's icon-grid options, built from the `icon` reference table
    /// (`AppDataStore.loadIcons`). Skips `icon_id` 0, whose `None` name is a sentinel rather than
    /// an asset: the grid clears an icon by re-clicking the selected one, so it needs no cell of
    /// its own for "none". Rows naming an asset that isn't bundled are dropped too.
    static func iconOptions(from icons: [IconRecord]) -> [CategoryIconOption] {
        icons.compactMap { record in
            guard record.id >= 1, validIconNames.contains(record.name) else { return nil }
            return CategoryIconOption(iconId: record.id, name: displayName(for: record.name), iconName: record.name)
        }
    }

    /// The facet colour-picker options, built from the `colour` reference table
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

    static let validIconNames: Set<String> = Set(iconOptions.map { $0.iconName })

    private static let defaultFacetIcons: [String] = [
        "ic_project",
        "ic_code",
        "ic_meeting",
        "ic_emails",
        "ic_calls",
        "ic_design",
        "ic_admin",
        "ic_reading",
        "ic_fitness",
        "ic_marketing",
        "ic_support",
        "ic_urgent"
    ]

    private static let defaultFacetNames: [String] = [
        "Project",
        "Code",
        "Meetings",
        "Emails",
        "Calls",
        "Design",
        "Admin",
        "Reading",
        "Fitness",
        "Marketing",
        "Support",
        "Urgent"
    ]

    static func defaultMappings() -> [FacetMapping] {
        // Default: every facet starts unassigned with a neutral gray color and no icon.
        return TimeFlipConstants.facetIDs.map { facetID in
            FacetMapping(
                facetID: facetID,
                name: "",
                iconName: ""
            )
        }
    }

    /// Tidies a typed category name: leading and trailing whitespace removed, and any internal run
    /// of whitespace collapsed to a single space. Deliberately not `sanitizeActivityName` -- that
    /// one strips everything outside letters, digits, spaces, `?` and `!`, which would turn a
    /// ticket-style name like `ACME-123` into `ACME123`.
    ///
    /// Collapsing matters beyond tidiness: it happens before the already-exists check, so
    /// `"Client  work"` is recognised as the `"Client work"` that already exists rather than
    /// quietly becoming a second category that looks identical in a list.
    static func normalizeCategoryName(_ value: String) -> String {
        value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    static func sanitizeActivityName(_ value: String) -> String {
        let filteredScalars = value.unicodeScalars.filter { allowedNameCharacters.contains($0) }
        return String(String.UnicodeScalarView(filteredScalars))
    }

    static func sanitizeIconName(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        return validIconNames.contains(trimmed) ? trimmed : ""
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
