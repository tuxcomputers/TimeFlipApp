import AppAuth
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
            // Deliberately not `.atomic`: an atomic write replaces whatever sits at `fileURL` via
            // rename, which severs a symlink *or* a hard link (e.g. one pointing at a repo
            // checkout for development) and leaves an unlinked plain file in its place. Writing
            // in place instead opens the existing path and overwrites its bytes directly, which
            // follows symlinks and preserves hard links.
            try data.write(to: fileURL)
        } catch {
            logger.error("Failed to write config.json: \(error.localizedDescription, privacy: .public)")
        }
    }
}

/// Session-only stand-in for `KeychainAuthStateStore` while developer mode is active — OAuth
/// tokens aren't part of config.json, so this just keeps them in memory instead of ever touching
/// the Keychain (re-authenticating each launch is expected in developer mode).
final class DeveloperModeGoogleAuthStateStore: GoogleAuthStateStore, @unchecked Sendable {
    private var state: OIDAuthState?

    func loadState() throws -> OIDAuthState? { state }

    func saveState(_ state: OIDAuthState) throws {
        self.state = state
    }

    func clearState() throws {
        state = nil
    }
}
