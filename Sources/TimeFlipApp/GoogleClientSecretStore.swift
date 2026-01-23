import Foundation

protocol GoogleClientSecretStore {
    func loadSecret() throws -> String?
    func saveSecret(_ secret: String?) throws
}

final class KeychainGoogleClientSecretStore: GoogleClientSecretStore {
    private let store: GoogleOAuthKeychainStore

    init(
        store: GoogleOAuthKeychainStore = .shared
    ) {
        self.store = store
    }

    func loadSecret() throws -> String? {
        try store.loadClientSecret()
    }

    func saveSecret(_ secret: String?) throws {
        try store.saveClientSecret(secret)
    }
}
