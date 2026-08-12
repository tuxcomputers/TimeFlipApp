import Foundation
@testable import TimeFlipApp

/// In-memory stand-ins for AppState's Keychain-backed stores, so tests exercise AppState without
/// touching a real Keychain (which is slow and stateful across test runs in a sandboxed test
/// environment). There was a UserDefaults stand-in here too until the preferences blob was removed.

final class InMemoryGoogleClientSecretStore: GoogleClientSecretStore, @unchecked Sendable {
    private var secret: String?

    func loadSecret() throws -> String? { secret }
    func saveSecret(_ secret: String?) throws { self.secret = secret }
}

final class InMemoryDevicePasswordStore: TimeFlipDevicePasswordStoring, @unchecked Sendable {
    private var password: String?

    func loadPassword() throws -> String? { password }
    func savePassword(_ password: String?) throws { self.password = password }
}

/// Stands in for the real `config.json`. Records every save so a test can assert not just what the
/// file ends up holding, but whether the app wrote to it at all.
final class InMemoryDeveloperConfigStore: DeveloperConfigStoring, @unchecked Sendable {
    private(set) var stored: DeveloperConfigPayload?
    private(set) var saves: [DeveloperConfigPayload] = []

    init(stored: DeveloperConfigPayload? = nil) {
        self.stored = stored
    }

    func load() -> DeveloperConfigPayload? { stored }

    func save(_ payload: DeveloperConfigPayload) {
        saves.append(payload)
        stored = payload
    }
}
