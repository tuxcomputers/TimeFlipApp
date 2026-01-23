import AppAuth
import Foundation

protocol GoogleAuthStateStore: Sendable {
    func loadState() throws -> OIDAuthState?
    func saveState(_ state: OIDAuthState) throws
    func clearState() throws
}

final class KeychainAuthStateStore: GoogleAuthStateStore, @unchecked Sendable {
    private let store: GoogleOAuthKeychainStore

    init(
        store: GoogleOAuthKeychainStore = .shared
    ) {
        self.store = store
    }

    func loadState() throws -> OIDAuthState? {
        try store.loadAuthState()
    }

    func saveState(_ state: OIDAuthState) throws {
        try store.saveAuthState(state)
    }

    func clearState() throws {
        try store.clearAuthState()
    }
}
