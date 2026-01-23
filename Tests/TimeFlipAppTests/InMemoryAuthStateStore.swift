import AppAuth
import Foundation
@testable import TimeFlipApp

/// Lightweight in-memory store to keep GoogleAuthManager happy in tests.
final class InMemoryAuthStateStore: GoogleAuthStateStore, @unchecked Sendable {
    private var state: OIDAuthState?

    func saveState(_ state: OIDAuthState) throws {
        self.state = state
    }

    func loadState() throws -> OIDAuthState? {
        state
    }

    func clearState() throws {
        state = nil
    }
}
