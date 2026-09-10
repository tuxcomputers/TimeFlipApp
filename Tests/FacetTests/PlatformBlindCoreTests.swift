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
///
/// ## What this cannot see, which matters as much as what it can
///
/// **It only catches a violation that announces itself with a platform conditional.** An adapter that reaches a
/// platform capability through a concrete type or a hard static carries no `#if`, so it is invisible here and
/// never joins the allowlist. **This list emptying would therefore not mean the target had been reached**, and
/// the rule in `CLAUDE.md` should not be read as saying it would.
///
/// Measured on 2026-09-10: the allowlist is 7 files and at least 22 files in the core reach for a platform
/// capability with no conditional at all. The sharpest example is `InstanceLock`, which is `flock`, `errno` and
/// `strerror` with **zero** `#if` in the file. It does not compile on Windows, where the equivalent is a named
/// mutex or `LockFileEx`, which is a different implementation and so a port by this rule's own test. This check
/// will never report it.
///
/// Others in the same position: `DatabaseConnection` and three more files on `sqlite3_*`; `RunLoop.main` in five
/// modules; `FileManager.default.urls(for: .applicationSupportDirectory, ...)` in five; `Bundle.main` in four.
///
/// **Widening this to catch them is a real candidate and not a small one**: it means naming the platform-only
/// symbols worth failing on, which is a judgement per symbol rather than a pattern. Until that exists, treat a
/// green run here as "nothing new has declared itself", not as "the core is platform-blind".
///
/// The scan is also **not recursive** (`contentsOfDirectory` below). `Sources/FacetCore` is flat today apart from
/// `Resources/`, so nothing is missed; a subdirectory would carry adapters past it silently.
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
    /// - `GoogleLoopbackListener`: two implementations in one file, `Network.framework` and raw sockets. A port
    ///   wearing an `#if`. **The last one**, and the only kind left: everything else here has moved to the target
    ///   it belongs to, and this cannot until it is split in two.
    ///
    /// **The BlueZ transport came off on 2026-09-10**, six files to `FacetLinux`: `SystemBus`, `BlueZRadio`,
    /// `BlueZGatt`, `DBusValue`, `BlueZObjectTree` and `BlueZAddress`. They were moved and not altered, which was
    /// the instruction, the only change being the `import FacetCore` four of them need to see types they use from
    /// outside it now. The allowlist said this was blocked on the radio port existing. It was not: the port is
    /// what a *second* adapter needs, and putting an adapter in its own target needs nothing but the move.
    ///
    /// **Three came off on 2026-09-10 and the reason is worth keeping.** `KeychainSecretStore` and
    /// `SecretToolStore` moved to `FacetMac` and `FacetLinux`, and `SecretStore` lost the `SecretStores.platform`
    /// that chose between them, which was the core choosing however small the conditional. Both composition roots
    /// hand the adapter over now. Their conditionals went with them rather than travelling: which square is built
    /// is the manifest's business, so an adapter that has reached its own target needs no `#if` at all.
    ///
    /// `SecretToolStore` is also the one this check found that the hand survey before it had missed, because that
    /// grep matched `#if canImport` and the file opened `#if !canImport`.
    private static let adaptersStillInTheCore: Set<String> = [
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
