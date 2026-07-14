import AppKit
import SwiftUI

protocol PreferencesStore {
    func load() -> PreferencesPayload?
    func save(_ payload: PreferencesPayload)
}

struct PreferencesPayload: Codable {
    var facetMappings: [FacetMappingRecord] = []
    var googleCalendarID: String?
    var googleCalendarName: String?
    var googleSheetURL: String?
    var googleClientID: String?
    var isPaired: Bool = false
    // optional for backward compatibility
    // swiftlint:disable:next discouraged_optional_boolean
    var wantsPairing: Bool?
    var pairedDeviceName: String?
    var pairedDeviceUUID: String?
    var devicePassword: String? = TimeFlipConstants.defaultPassword
    var ledBrightnessPercent: UInt8?
    var autoPauseMinutes: UInt16?
    var blinkIntervalSeconds: UInt8?
    var doubleTapParameters: DoubleTapParameters?
}

struct FacetMappingRecord: Codable {
    var facetID: UInt8
    var name: String
    var iconName: String
    var color: ColorComponents
    var limitMinutes: Int?
}

struct ColorComponents: Codable, Equatable {
    var red: Double
    var green: Double
    var blue: Double
    var alpha: Double
}

final class UserDefaultsPreferencesStore: PreferencesStore {
    private let defaults: UserDefaults
    private let key = "timeflip.preferences"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> PreferencesPayload? {
        if let data = defaults.data(forKey: key), let payload = decode(data) {
            return payload
        }

        return nil
    }

    func save(_ payload: PreferencesPayload) {
        guard let data = try? JSONEncoder().encode(payload) else {
            return
        }
        defaults.set(data, forKey: key)
    }

    private func decode(_ data: Data) -> PreferencesPayload? {
        try? JSONDecoder().decode(PreferencesPayload.self, from: data)
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
}

extension FacetMappingRecord {
    init(mapping: FacetMapping) {
        self.facetID = mapping.facetID
        self.name = mapping.name
        self.iconName = mapping.iconName
        self.color = ColorComponents(color: mapping.color)
        self.limitMinutes = mapping.limitMinutes
    }
}
