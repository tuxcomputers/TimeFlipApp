@testable import FacetCore
import Foundation
import Testing

/// Checks that `FacetCore` does not know what platform it is running on.
///
/// **The rule is in `CLAUDE.md` under *The core is platform-blind, and every platform capability is a port*.**
/// The core states what it needs as a protocol and something outside it hands over the thing that does it; it
/// holds no adapter and chooses no adapter. This reads the sources and fails on a platform conditional it does
/// not recognise, because the type system will not answer "is anything violating this" and something has to.
///
/// **Same tactic as `Package.swift`'s two exclusion lists and `LinkEndedFanOutTests`**, and the same shape: a
/// shrinking allowlist that is the debt written down. Adding to it is a decision to be argued for; removing from
/// it is the work. A new adapter in the core fails here rather than joining the list quietly.
@Suite
struct PlatformBlindCoreTests {
    private static var core: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Tests/FacetTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // the root
            .appendingPathComponent("Sources/FacetCore", isDirectory: true)
    }

    /// A portability shim is the same code reaching the same Foundation through a different spelling. It is
    /// noise rather than architecture and may stay.
    ///
    /// **The test between a shim and a port**: would a third platform need a different *implementation*, or
    /// merely a different *import*? Different implementation is a port and belongs in a platform target.
    private static let shims: Set<String> = [
        "FoundationNetworking",   // `URLSession` needs its own import on Linux and is otherwise the same code
        "CoreGraphics",           // `CGFloat`
        "Darwin",                 // `setvbuf`, which glibc refuses and which is guarded rather than solved
        "CryptoKit",              // SHA-256, with `PortableSHA256` as the same answer computed by hand
        "Glibc",                  // the other half of the above
    ]

    /// Adapters sitting in the core today, and the one place the core chooses one.
    ///
    /// **This list is the debt and it is meant to empty**, file by file, as each moves to `FacetMac` or
    /// `FacetLinux` and the composition root injects it instead.
    ///
    /// - `BlueZRadio`, `BlueZGatt`, `SystemBus`: the Linux radio transport, belonging in `FacetLinux`. Waiting
    ///   on the radio port, which does not exist yet: candidate 1 of `docs/architecture-review-2026-09.md`.
    /// - `KeychainSecretStore` and `SecretToolStore`: the Darwin and Linux secret adapters, belonging in
    ///   `FacetMac` and `FacetLinux`. Candidate 3 built the port and left both adapters here, which was half
    ///   the move. **`SecretToolStore` was missed by the hand survey that preceded this test**, because that
    ///   grep matched `#if canImport` and this file opens `#if !canImport`. It is the first thing this check
    ///   found that a person had not.
    /// - `SecretStore`: holds `SecretStores.platform`, which is the core choosing. It goes when `main.swift`
    ///   injects the adapter instead.
    /// - `GoogleLoopbackListener`: two implementations in one file, `Network.framework` and raw sockets. A port
    ///   wearing an `#if`.
    private static let adaptersStillInTheCore: Set<String> = [
        "BlueZRadio",
        "BlueZGatt",
        "SystemBus",
        "KeychainSecretStore",
        "SecretToolStore",
        "SecretStore",
        "GoogleLoopbackListener",
    ]

    private struct Conditional {
        let file: String
        let line: Int
        let text: String
        /// What it asks about: `canImport(Security)` yields `Security`.
        let subject: String
    }

    private func conditionals() throws -> [Conditional] {
        let files = try FileManager.default
            .contentsOfDirectory(at: Self.core, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        var found: [Conditional] = []
        for file in files {
            let name = file.deletingPathExtension().lastPathComponent
            for (index, raw) in try String(contentsOf: file, encoding: .utf8).split(
                separator: "\n", omittingEmptySubsequences: false
            ).enumerated() {
                let line = raw.trimmingCharacters(in: .whitespaces)
                guard line.hasPrefix("#if"), line.contains("canImport(") || line.contains("os(") else { continue }
                // `#if canImport(Security)` and `#if !canImport(Security)` alike; the subject is what matters.
                let parts = line.components(separatedBy: CharacterSet(charactersIn: "()"))
                let subject = parts.count > 1 ? parts[1] : line
                found.append(Conditional(file: name, line: index + 1, text: line, subject: subject))
            }
        }
        return found
    }

    @Test("FacetCore holds no platform adapter that is not on the allowlist")
    func theCoreHoldsNoUnlistedAdapter() throws {
        let all = try conditionals()

        // The premise. A scan finding nothing is how a check like this fails open, and this one has known
        // work outstanding, so it should never be empty until the allowlist is.
        #expect(!all.isEmpty, "the scan found no conditionals at all, so it has stopped working")

        for conditional in all where !Self.shims.contains(conditional.subject) {
            #expect(
                Self.adaptersStillInTheCore.contains(conditional.file),
                """
                \(conditional.file).swift:\(conditional.line) asks what platform it is on \
                (`\(conditional.text)`) and is not a known portability shim. The core states what it needs as a \
                protocol and something outside it hands over the thing that does it: put the adapter in \
                FacetMac or FacetLinux and let main.swift inject it. See CLAUDE.md, "The core is platform-blind, \
                and every platform capability is a port". If it is genuinely a shim, that a third platform would \
                need only a different import for, add its subject to `shims` and say why.
                """
            )
        }
    }

    @Test("The allowlist has nothing stale on it")
    func theAllowlistIsHonest() throws {
        let offenders = Set(
            try conditionals()
                .filter { !Self.shims.contains($0.subject) }
                .map(\.file)
        )
        for listed in Self.adaptersStillInTheCore.sorted() {
            #expect(
                offenders.contains(listed),
                """
                \(listed) is on `adaptersStillInTheCore` and no longer asks what platform it is on. \
                That is the debt being paid: take it off the list, so the list goes on meaning what it says.
                """
            )
        }
    }
}
