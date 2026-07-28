import AppKit
import OSLog
import SwiftUI

protocol PreferencesStore {
    func load() -> PreferencesPayload?
    func save(_ payload: PreferencesPayload)
    /// True if a preferences blob is present, regardless of whether `load()` could decode it —
    /// lets callers tell "nothing stored yet" (fine to persist defaults) apart from "stored data
    /// existed but failed to decode" (should not be silently clobbered with defaults).
    func hasStoredPayload() -> Bool
}

struct PreferencesPayload: Codable {
    var facetMappings: [FacetMappingRecord] = []
}

struct FacetMappingRecord: Codable {
    var facetID: UInt8
    var name: String
    var iconName: String
}

struct ColorComponents: Codable, Equatable {
    var red: Double
    var green: Double
    var blue: Double
    var alpha: Double

    /// The LED off. Command `0x11` takes an RGB triple with no separate enable, so all-zero is the
    /// only way to say "don't light this facet" -- see `AppState.facetLEDColours`.
    static let off = ColorComponents(red: 0, green: 0, blue: 0, alpha: 1)
}

final class UserDefaultsPreferencesStore: PreferencesStore {
    private let defaults: UserDefaults
    private let key = "timeflip.preferences"
    private let logger = Logger(subsystem: AppIdentifiers.subsystem, category: "preferences-store")

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> PreferencesPayload? {
        if let data = defaults.data(forKey: key), let payload = decode(data) {
            return payload
        }

        return nil
    }

    func hasStoredPayload() -> Bool {
        defaults.data(forKey: key) != nil
    }

    func save(_ payload: PreferencesPayload) {
        guard let data = try? JSONEncoder().encode(payload) else {
            return
        }
        defaults.set(data, forKey: key)
    }

    private func decode(_ data: Data) -> PreferencesPayload? {
        do {
            return try JSONDecoder().decode(PreferencesPayload.self, from: data)
        } catch {
            logger.error("Failed to decode stored preferences: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}

extension ColorComponents {
    init(color: Color) {
        // Encode in sRGB to match `color` below; mixing color spaces drifts the
        // stored components a little on every save/load round trip.
        let nsColor = NSColor(color).usingColorSpace(.sRGB) ?? NSColor.gray
        self.red = Double(nsColor.redComponent)
        self.green = Double(nsColor.greenComponent)
        self.blue = Double(nsColor.blueComponent)
        self.alpha = Double(nsColor.alphaComponent)
    }

    var color: Color {
        Color(.sRGB, red: red, green: green, blue: blue, opacity: alpha)
    }

    /// Parses an `"#rrggbb"` (or `"rrggbb"`) hex string into opaque sRGB components. Returns `nil`
    /// for anything that isn't exactly six hex digits (e.g. an empty/`NULL` `device_hex`).
    init?(hex: String) {
        var value = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("#") { value.removeFirst() }
        guard value.count == 6, let rgb = UInt32(value, radix: 16) else { return nil }
        self.red = Double((rgb >> 16) & 0xFF) / 255.0
        self.green = Double((rgb >> 8) & 0xFF) / 255.0
        self.blue = Double(rgb & 0xFF) / 255.0
        self.alpha = 1.0
    }

    /// The triple as command `0x11` carries it: 16 bits per channel, so 0-1 scales to 0-65535.
    /// Shared by the write itself and the log of what was written, so the logged numbers are the
    /// ones that actually went out rather than a second, drifting calculation.
    var deviceRGB16: (red: UInt16, green: UInt16, blue: UInt16) {
        func scale(_ channel: Double) -> UInt16 {
            UInt16(max(0, min(65535, Int((channel * 65535).rounded()))))
        }
        return (scale(red), scale(green), scale(blue))
    }

    /// `"#rrggbb"`, the inverse of `init?(hex:)`. Alpha is dropped: the LED has no notion of it.
    var hexString: String {
        func scale(_ channel: Double) -> Int {
            max(0, min(255, Int((channel * 255).rounded())))
        }
        return String(format: "#%02x%02x%02x", scale(red), scale(green), scale(blue))
    }
}

extension FacetMappingRecord {
    init(mapping: FacetMapping) {
        self.facetID = mapping.facetID
        self.name = mapping.name
        self.iconName = mapping.iconName
    }
}
