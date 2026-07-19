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

    /// Whether debug messages are actually emitted right now -- true only when `isEnabled` (the
    /// compile-time dev flag above) is also on. Set once at startup from the `debug` setting's
    /// `enabled` field (see `AppDataStore.loadDebugEnabled()`), so a user can turn terminal
    /// debug logging off (or back on) themselves by editing that DB setting directly, without a
    /// rebuild. Defaults to `true` (matching the seeded default) until that startup assignment
    /// runs. Like other DB-only settings, changing it takes effect on the next app launch.
    /// `nonisolated(unsafe)`: written once at launch before any concurrent debug-print call site
    /// could plausibly run, then only ever read afterward -- a torn read of a `Bool` isn't a
    /// real hazard here, and `debugPrint` is called from several non-MainActor contexts.
    nonisolated(unsafe) static var isDebugSettingEnabled = true

    /// Set once at startup (see `ApplicationDelegate.applicationDidFinishLaunching`) to
    /// `AppDataStore.recordDebugLog(tag:message:)`, so every debug message is also persisted to
    /// the `debug_log` table for later analysis, alongside printing it to the terminal. `nil`
    /// until wired up, so any call before that point just prints as before. `nonisolated(unsafe)`
    /// for the same reason as `isDebugSettingEnabled` above.
    nonisolated(unsafe) static var logSink: ((DebugTag, String) -> Void)?

    /// Identifies the subsystem/action a dev-only debug print originates from. `bracketed`
    /// right-pads the tag's name to the width of the longest case below, so every dev-check
    /// console line lines up (e.g. `[TimeFlip ]` / `[dev-check]`) regardless of call order. Adding
    /// a new case automatically re-measures `width` and re-pads every existing tag to match — no
    /// hand-adjustment of other tags is needed when a new one is a different length.
    enum DebugTag: String, CaseIterable {
        case timeFlip = "TimeFlip"
        case devCheck = "dev-check"
        case history = "history"
        case battery = "battery"
        case dbType = "db-type"
        case doubleTap = "double-tap"
        case deviceSync = "device-sync"
        case autoPause = "auto-pause"
        case led = "led"

        private static let width = allCases.map { $0.rawValue.count }.max() ?? 0

        fileprivate var bracketed: String {
            "[\(rawValue.padding(toLength: Self.width, withPad: " ", startingAt: 0))]"
        }
    }

    private static let debugTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        formatter.timeZone = .current
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    /// Prints a dev-only console message prefixed with a zero-padded 24-hour local timestamp and
    /// `tag`'s padded, bracketed name, gated on `isEnabled` — e.g.
    /// `13:25:38 [TimeFlip ] Login accepted, code=0x02`. `message` is an autoclosure so string
    /// interpolation is skipped entirely when developer mode is off.
    static func debugPrint(_ tag: DebugTag, _ message: @autoclosure () -> String) {
        guard isEnabled, isDebugSettingEnabled else { return }
        let text = message()
        print("\(debugTimeFormatter.string(from: Date())) \(tag.bracketed) \(text)")
        logSink?(tag, text)
    }
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
