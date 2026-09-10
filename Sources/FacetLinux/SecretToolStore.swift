import FacetCore
import Foundation

/// The login keyring, reached through `secret-tool`. **The Linux stand-in for the Keychain**, and the one
/// place the two stores that need it go through.
///
/// `DevicePINStore` and `GoogleTokenStore` keep their Darwin bodies and branch to this at compile time,
/// which is the shape `docs/linux-port.md` item 7 settled on: both are enum namespaces of static
/// functions, so a platform branch inside them costs no call site anything and no runtime seam is needed.
///
/// **Why a subprocess and not the library.** libsecret's simple API -- `secret_password_store_sync` and
/// friends -- is **variadic C**, which Swift cannot call at all (measured against
/// `/usr/include/libsecret-1/libsecret/secret-password.h`, 2026-09-07). Reaching it in-process means the
/// `*v_sync` variants, which take a `GHashTable`, which means a second system-library target for
/// glib-2.0, a `SecretSchema` assembled by hand and GError plumbing. `secret-tool` is the same store
/// through a documented command, it is what this desktop already keeps `gh`'s token in, and it is
/// perhaps sixty lines rather than two hundred. **If packaging ever objects to depending on a binary, the
/// swap is entirely inside this file**: nothing above it knows how the secret is fetched.
///
/// **What it costs, said plainly.** `libsecret-tools` has to be installed, and the secret crosses a pipe
/// to a child process rather than staying in this one's memory. Neither is free; both were preferred to
/// the alternative of a port that cannot keep a secret at all.
package struct SecretToolStore: SecretStore {
    package init() {}

    /// **`secret-tool` exits 1 both for a secret that is not there and for a keyring it cannot reach**, so
    /// the exit code alone cannot tell them apart. Measured 2026-09-07: a lookup that finds nothing writes
    /// nothing to stderr, while one against an unreachable bus writes `secret-tool: Could not connect:
    /// ...` -- so an empty stderr is what says "not there" and anything on it says "could not ask".
    ///
    /// Collapsing the two would be the fault `DevicePINStore.Lookup` was written to avoid: the app would
    /// rotate the PIN of a cube that has a perfectly good one it simply could not read.
    private static func answer(status: Int32, out: Data, err: String) -> SecretLookup {
        if status == 0 {
            // **Not trimmed.** `secret-tool lookup` returns the stored bytes and nothing else -- measured
            // as exactly six bytes for a six-digit PIN, no trailing newline -- and trimming would corrupt
            // a secret that legitimately ends in whitespace.
            guard let text = String(data: out, encoding: .utf8) else { return .unavailable(malformed) }
            return .found(text)
        }
        return err.isEmpty ? .missing : .unavailable(status)
    }

    /// `secret-tool` could not be launched at all: not installed, or not on `PATH`.
    private static let couldNotRun: Int32 = -1
    /// It answered with bytes that are not UTF-8, which nothing this app stores ever is.
    private static let malformed: Int32 = -2

    /// Stores a secret under `service`/`account`, replacing whatever was there.
    ///
    /// **Read back before it answers `true`**, which is the Darwin path's rule and matters as much here:
    /// what follows a `true` for a PIN is a cube left on it, so a write believed on the strength of an
    /// exit code alone would be a cube nobody can log into.
    @discardableResult
    package func store(service: String, account: String, label: String, secret: String) -> Bool {
        guard let result = run(
            ["store", "--label", label, "service", service, "account", account],
            input: secret
        ) else { return false }
        guard result.status == 0 else { return false }
        return lookUp(service: service, account: account) == .found(secret)
    }

    /// What is stored under `service`/`account`.
    package func lookUp(service: String, account: String) -> SecretLookup {
        guard let result = run(["lookup", "service", service, "account", account]) else {
            return .unavailable(couldNotRun)
        }
        return answer(status: result.status, out: result.out, err: result.err)
    }

    /// Forgets it. **`true` when there was nothing to forget**, matching the Darwin path: the caller asked
    /// for there to be no secret and there is none. `secret-tool clear` exits 1 in that case, so the same
    /// stderr test tells it from a keyring that would not answer (measured 2026-09-07).
    @discardableResult
    package func clear(service: String, account: String) -> Bool {
        guard let result = run(["clear", "service", service, "account", account]) else { return false }
        if result.status == 0 { return true }
        return result.err.isEmpty
    }

    /// Runs `secret-tool`, or `nil` if it could not be started.
    ///
    /// Through `/usr/bin/env` so `PATH` decides where the binary is, rather than this file asserting
    /// `/usr/bin/secret-tool` and being wrong on a distribution that puts it elsewhere.
    ///
    /// **Both pipes are drained before waiting for exit.** A process whose output fills the pipe buffer
    /// while nobody is reading it blocks forever, and `waitUntilExit` first is how that deadlock is
    /// written. A secret is far too small to fill a buffer, which makes this the kind of bug that would
    /// appear years later on something else.
    private static func run(_ arguments: [String], input: String? = nil) -> (status: Int32, out: Data, err: String)? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["secret-tool"] + arguments

        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        let standardInput = Pipe()
        process.standardInput = standardInput

        do {
            try process.run()
        } catch {
            return nil
        }

        if let input {
            standardInput.fileHandleForWriting.write(Data(input.utf8))
        }
        // Closed either way: `secret-tool lookup` reads no input, but a child holding an open stdin it is
        // not reading is harmless while one waiting on an EOF that never comes is not.
        standardInput.fileHandleForWriting.closeFile()

        let out = output.fileHandleForReading.readDataToEndOfFile()
        let err = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        return (
            process.terminationStatus,
            out,
            String(data: err, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        )
    }
}
