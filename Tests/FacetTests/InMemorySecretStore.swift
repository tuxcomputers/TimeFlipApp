@testable import FacetCore
import Foundation

/// A `SecretStore` that keeps what it is given, and can be told to refuse.
///
/// **The third conformance, and the one that makes the seam worth having.** The Keychain and `secret-tool` are the
/// two real ones, so `SecretStore` passes the deletion test on them alone; what this adds is that everything above
/// it becomes testable. Before candidate 3, `DevicePINStore` and `GoogleTokenStore` were enums of statics bound to
/// the platform, and `DevicePINStore`'s own doc said it was "deliberately not unit tested" because "CI has no
/// Keychain" -- which was true of the file, and the file held the naming, the read-back rule and the meaning as
/// well as the `SecItem` calls.
///
/// **`unavailable` is the case worth being able to produce**, and the reason this is not just a dictionary. Every
/// decision that matters downstream turns on telling "there is nothing stored" from "this process could not read
/// what is stored", and until now nothing could make a real store answer the second on demand.
final class InMemorySecretStore: SecretStore, @unchecked Sendable {
    private struct Key: Hashable {
        let service: String
        let account: String
    }

    private var secrets: [Key: String] = [:]

    /// When set, every call answers this instead of doing anything. `nil` is a store that works.
    var refusesWith: Int32?

    /// Refuses writes while still answering reads.
    ///
    /// A separate flag from `refusesWith` because they are separate faults and the app acts differently on each: a
    /// keyring that cannot be written is one the app must not then leave a cube depending on, while one that cannot
    /// be read may be holding a perfectly good secret.
    var refusesWrites = false

    /// Whether a write is read back before it is believed. The real stores both do; a store that says `true` and
    /// did not keep it is exactly what the read-back exists to catch, so a test can build one.
    var silentlyDiscardsWrites = false

    /// Every secret written, in order.
    private(set) var written: [String] = []

    private(set) var storeCount = 0
    private(set) var lookUpCount = 0
    private(set) var clearCount = 0
    /// The labels writes were given, which nothing but a human ever sees and so is otherwise unassertable.
    private(set) var labels: [String] = []

    func store(service: String, account: String, label: String, secret: String) -> Bool {
        storeCount += 1
        labels.append(label)
        if refusesWith != nil || refusesWrites { return false }
        written.append(secret)
        if !silentlyDiscardsWrites {
            secrets[Key(service: service, account: account)] = secret
        }
        // The contract both real stores keep: answer `true` only where it can be read back.
        return lookUp(service: service, account: account) == .found(secret)
    }

    func lookUp(service: String, account: String) -> SecretLookup {
        lookUpCount += 1
        if let code = refusesWith { return .unavailable(code) }
        guard let secret = secrets[Key(service: service, account: account)] else { return .missing }
        return .found(secret)
    }

    func clear(service: String, account: String) -> Bool {
        clearCount += 1
        if refusesWith != nil { return false }
        secrets.removeValue(forKey: Key(service: service, account: account))
        return true
    }

    /// What the store holds, for a test that wants to set the scene rather than write through the interface.
    /// `nil` removes it.
    func put(_ secret: String?, service: String, account: String) {
        secrets[Key(service: service, account: account)] = secret
    }

    /// What is actually held, whatever the refusal flags say.
    ///
    /// For a test that has made the store unreadable and still needs to assert the secret survived, which is the
    /// case `unavailable` exists for: the item is there and this process cannot see it.
    func peek(service: String, account: String) -> String? {
        secrets[Key(service: service, account: account)]
    }
}
