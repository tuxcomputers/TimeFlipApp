import Foundation
import OSLog

/// Developer mode: when enabled, Google API and device PIN settings are read from and written
/// back to `config.json` (in Application Support/TimeFlip, alongside the app database) instead
/// of Keychain/UserDefaults.
///
/// To remove developer mode entirely: delete this file, then remove every
/// `DeveloperMode.isEnabled` call site (and the `isDeveloperConfigLoaded` flag) from AppState.swift.
enum DeveloperMode {
    static let isEnabled = true
}

struct DeveloperConfigPayload: Codable {
    var googleClientID: String?
    var googleClientSecret: String?
    var devicePassword: String?

    enum CodingKeys: String, CodingKey {
        case googleClientID = "client_id"
        case googleClientSecret = "client_secret"
        case devicePassword = "PIN"
    }
}

protocol DeveloperConfigStoring {
    func load() -> DeveloperConfigPayload?
    func save(_ payload: DeveloperConfigPayload)
}

final class DeveloperConfigStore: DeveloperConfigStoring, @unchecked Sendable {
    static let shared = DeveloperConfigStore()

    private let fileURL: URL
    private let logger = Logger(subsystem: AppIdentifiers.subsystem, category: "developer-config")

    init(fileURL: URL = DeveloperConfigStore.defaultFileURL) {
        self.fileURL = fileURL
    }

    private static var defaultFileURL: URL {
        let fileManager = FileManager.default
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("TimeFlip", isDirectory: true)
            .appendingPathComponent("config.json")
    }

    func load() -> DeveloperConfigPayload? {
        guard let data = try? Data(contentsOf: fileURL) else {
            return nil
        }
        do {
            return try JSONDecoder().decode(DeveloperConfigPayload.self, from: data)
        } catch {
            logger.error("Failed to decode config.json: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    func save(_ payload: DeveloperConfigPayload) {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(payload)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            logger.error("Failed to write config.json: \(error.localizedDescription, privacy: .public)")
        }
    }
}
