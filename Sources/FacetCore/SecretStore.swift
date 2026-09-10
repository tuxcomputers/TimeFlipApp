import Foundation

/// What a secret store said when asked for something.
///
/// **Three answers, not two, and the third is the whole reason this type exists.** "There is nothing stored" and
/// "this process could not read what is stored" have opposite remedies: the first is fixed by signing in or by
/// pairing, the second by working out why the item cannot be read. Offering a sign-in for the second throws away a
/// working connection to solve a problem it does not have, and rotating a cube's PIN on the second leaves a cube
/// nobody can log into.
///
/// **One type where there were three.** `SecretToolStore.Answer`, `DevicePINStore.Lookup` and
/// `GoogleTokenStore.Lookup` were the same three cases declared three times, with the comment on `unavailable`
/// copied word for word between the last two, and six `#if` branches whose only work was translating one into
/// another. That is candidate 3 of `docs/architecture-review-2026-09.md`.
///
/// `Int32` rather than `OSStatus` for the code: the same type on Darwin, where `OSStatus` is a typealias for it, and
/// a type that exists everywhere. What the number means belongs to whichever store answered.
package enum SecretLookup: Equatable {
    case found(String)
    case missing
    case unavailable(Int32)
}

/// Somewhere durable to keep a secret, keyed by a service and an account.
///
/// **Two real adapters, which is what makes this a seam rather than a description of one.** The login Keychain on
/// Darwin and the login keyring through `secret-tool` on Linux, plus an in-memory one in the tests. Before this the
/// choice was an `#if` inside each of six methods, so nothing could be substituted and neither store had a single
/// test: `DevicePINStore`'s own doc said it was "deliberately not unit tested" because "CI has no Keychain", which
/// was true of the whole file rather than only of the part that talks to the Keychain.
///
/// **Nothing here knows what a secret is for.** A service and an account are the two halves of a key and that is
/// all; the PIN's meaning, the token's meaning, and the rule that a write is read back before it is believed all
/// belong to `DevicePINStore` and `GoogleTokenStore` above.
///
/// **Not `async`, deliberately.** Every implementation is synchronous today, the Keychain because `SecItem*` is and
/// `secret-tool` because it waits on a child process, and the callers are already on the main actor. Making it
/// `async` would buy nothing and would make `DevicePINSource`'s ordering rules harder to state.
package protocol SecretStore: Sendable {
    /// Stores a secret under `service`/`account`, replacing whatever was there.
    ///
    /// `label` is what a keyring shows a human; the Keychain has no equivalent and ignores it.
    ///
    /// **Answers `true` only where the secret can be read back**, which is `CLAUDE.md`'s rule about a write that
    /// reports success and did not happen.
    @discardableResult
    func store(service: String, account: String, label: String, secret: String) -> Bool

    func lookUp(service: String, account: String) -> SecretLookup

    /// Forgets it. **`true` when there was nothing to delete**: the caller asked for there to be none, and there is
    /// none.
    @discardableResult
    func clear(service: String, account: String) -> Bool
}

// **There is deliberately nothing here that picks an implementation.**
//
// This file used to end with a `SecretStores.platform` that chose the Keychain or `secret-tool` behind one `#if`,
// and that was described as a win over the six branches it replaced. It was not: a core type picking its own
// implementation, however small the conditional, is the core caring what platform it is on. `CLAUDE.md` names
// the case directly under *The core is platform-blind, and every platform capability is a port*.
//
// **On Windows it would have compiled and handed back a store that runs `/usr/bin/env secret-tool`**, because
// the choice was `canImport(Security)` and everything else fell through to the Linux branch. The core would
// have chosen, and chosen wrong, silently, at runtime.
//
// Both composition roots now build the adapter and hand it over: `KeychainSecretStore` in `FacetMac`,
// `SecretToolStore` in `FacetLinux`.
