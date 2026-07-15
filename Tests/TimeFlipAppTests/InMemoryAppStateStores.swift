import Foundation
@testable import TimeFlipApp

/// In-memory stand-ins for AppState's Keychain/UserDefaults-backed stores, so tests exercise
/// AppState without touching real UserDefaults or Keychain (which is slow and stateful across
/// test runs in a sandboxed test environment).
final class InMemoryPreferencesStore: PreferencesStore, @unchecked Sendable {
    private var stored: PreferencesPayload?

    func load() -> PreferencesPayload? { stored }
    func save(_ payload: PreferencesPayload) { stored = payload }
    func hasStoredPayload() -> Bool { stored != nil }
}

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
