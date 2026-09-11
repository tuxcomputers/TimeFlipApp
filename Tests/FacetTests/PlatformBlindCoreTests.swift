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
/// Measured on 2026-09-10, after the clock became a port: the conditional allowlist is down to 1 file, from 7,
/// and 11 files in the core still reach a platform capability with no conditional at all. The sharpest example
/// is `InstanceLock`, which is `flock`, `errno` and `strerror` with **zero** `#if` in the file. It does not
/// compile on Windows, where the equivalent is a named mutex or `LockFileEx`, which is a different
/// implementation and so a port by this rule's own test. The conditional scan will never report it.
///
/// Others in the same position: `DatabaseConnection` and three more files on `sqlite3_*`;
/// `FileManager.default.urls(for: .applicationSupportDirectory, ...)` in four; `Bundle.main` in four. That is
/// item 2 of `docs/architecture-ports-plan.md`.
///
/// **`theCoreUsesItsPorts` below is the widening**, and it works the only way this can be widened: by naming
/// the platform-only spellings worth failing on, one at a time. `RunLoop` and `Timer.scheduledTimer` are the
/// first two, added with the clock. Until a spelling is named, treat a green run here as "nothing new has
/// declared itself", not as "the core is platform-blind".
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
        // SHA-256, and the one entry here that is settled by something better than the shim-or-port test.
        // The `#else` branch is `PortableSHA256`, which is platform-free and already written, so a third
        // platform needs **nothing**: it falls into that branch and works. The `#if` is therefore an opt-in
        // to Apple's implementation on one platform, not a gap being filled per platform, and no caller can
        // tell which ran because SHA-256 is fully specified. `PortableSHA256`'s own tests check the two
        // agree, on Darwin, against the CryptoKit answer it is not being used for.
        "CryptoKit",
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
    /// `BlueZGatt`, `DBusValue`, `BlueZObjectTree` and `BlueZAddress` (the last of which is gone entirely since
    /// 2026-09-11, `DeviceHandle` having removed the reason for it). They were moved and not altered, which was
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

    /// Platform-only spellings the core may no longer use, with what to use instead.
    ///
    /// **This is the check being widened, one symbol at a time**, which is the only way it can be widened: the
    /// scan above sees a violation only where the violation announces itself with a `#if`, and the things doing
    /// the real damage carry none. Deciding a symbol belongs here is a judgement per symbol, so each row is a
    /// decision that was argued rather than a pattern that matched.
    ///
    /// **`RunLoop` is the first, added once the clock became a port on 2026-09-10.** Six modules built a `Timer`
    /// and added it to `RunLoop.main`, and `FacetLinux` never runs `RunLoop.main`, so on Linux the history fetch,
    /// the battery flash, the daily limit, the reconnect backoff, the settings debounce and the quit deadline
    /// were all silently dead. Nothing declared itself, so nothing here could have caught it.
    ///
    /// `Timer.scheduledTimer` is on the list beside it because it adds to the current run loop **without naming
    /// one**, which would have walked straight past a check that only looked for `RunLoop`.
    private static let bannedSpellings: [(symbol: String, instead: String)] = [
        ("RunLoop", "take a `Scheduler` and call `wake(in:)`; the run loop is `RunLoopScheduler`'s business"),
        ("Timer.scheduledTimer", "the same, and note this one adds to a run loop without naming it"),
    ]

    @Test("FacetCore names no platform-only spelling it has a port for")
    func theCoreUsesItsPorts() throws {
        let files = try FileManager.default
            .contentsOfDirectory(at: Self.core, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        #expect(!files.isEmpty, "the scan found no sources at all, so it has stopped working")

        for file in files {
            let name = file.lastPathComponent
            for (index, raw) in try String(contentsOf: file, encoding: .utf8).split(
                separator: "\n", omittingEmptySubsequences: false
            ).enumerated() {
                let line = raw.trimmingCharacters(in: .whitespaces)
                // Prose may name what the code may not, and `Scheduler` itself has to say what it replaced.
                guard !line.hasPrefix("//") else { continue }
                for banned in Self.bannedSpellings where line.contains(banned.symbol) {
                    Issue.record(
                        """
                        \(name):\(index + 1) names `\(banned.symbol)`, which the core has a port for: \
                        \(banned.instead). See CLAUDE.md, "The core is platform-blind, and every platform \
                        capability is a port".
                        """
                    )
                }
            }
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
