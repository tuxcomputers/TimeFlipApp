import SwiftUI

struct FacetMapping: Identifiable {
    let facetID: UInt8
    var name: String
    var iconName: String
    var color: Color
    var limitMinutes: Int

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

struct ActivityColorOption: Identifiable {
    let colourId: Int
    let name: String
    let color: Color

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

    /// The facet colour-picker options, built from the `colour` reference table
    /// (`AppDataStore.loadColours`). Each option's swatch is the row's `device_hex`; rows without
    /// one (e.g. the `blank` colour) are skipped.
    static func colorOptions(from colours: [ColourRecord]) -> [ActivityColorOption] {
        colours.compactMap { record in
            guard let hex = record.deviceHex, let components = ColorComponents(hex: hex) else {
                return nil
            }
            return ActivityColorOption(colourId: record.id, name: record.name, color: components.color)
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
                iconName: "",
                color: .gray,
                limitMinutes: 0
            )
        }
    }

    static var defaultActivities: [Activity] {
        iconOptions.map { Activity(name: $0.name, iconName: $0.iconName, limitMinutes: 0) }
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
