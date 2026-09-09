@testable import FacetCore
import Foundation
import Testing

/// Checks that every module holding per-link state is actually told when the link ends.
///
/// **This is candidate 5 of `docs/architecture-review-2026-09.md`, and it is a source-level check on purpose.**
/// Three modules reset themselves on `linkEnded`, each of them individually tested, and each carrying a comment
/// about a stall that shipped before it had one: `HistoryIngestor` left a fetch in flight "for the life of the
/// process, so every later refresh was refused and the app ingested no history again until it was relaunched", and
/// `FaceColourSync` left a flag true so "every connection after it would queue twelve faces and send none". What
/// no test covered was the *completeness of the list*, which is three lines in `main.swift`. A fourth module that
/// nobody adds there stalls the same way and says nothing.
///
/// **Why text rather than types.** The obvious version registers conformers of a protocol, and it does not help:
/// Swift will not enumerate conformers, so the registry would be a hand-written list of `add` calls and forgetting
/// one would be exactly as silent as forgetting a line in a closure. Reading the sources is what can actually
/// answer "is anything missing", so that is what this does, and it is the same tactic
/// `scripts/check_interactive_checklists.sh` uses for the scripted suite.
///
/// **What this does not check**: that `linkEnded` does the right thing, which is each module's own suite; and the
/// `onCubeSettled` side, which is deliberately *not* the same list. `HistoryIngestor` hangs off the earlier
/// `onCubeReady` because a fetch is a question rather than a command and wants to be first in the queue, so the
/// two moments have different members by design and unifying them would be a bug.
///
/// **It reads `Sources/FacetMac/main.swift` on either platform**, which is deliberate: the file is in the
/// repository whether or not this platform compiles it, so the Mac's wiring is checked from the Linux box too.
/// **When `FacetLinux` grows a radio it grows this fan-out as well**, and the day it does this test takes a second
/// path rather than a second copy: the list to check becomes both mains, and a module missing from either is the
/// same silent stall.
@Suite
struct LinkEndedFanOutTests {
    /// The repository root, from this file's own path, so nothing depends on the working directory a runner uses.
    private static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Tests/FacetTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // the root
    }

    /// Every type in `FacetCore` that declares `func linkEnded()`.
    private func typesThatResetOnLinkEnded() throws -> Set<String> {
        let core = Self.repositoryRoot.appendingPathComponent("Sources/FacetCore", isDirectory: true)
        let files = try FileManager.default.contentsOfDirectory(at: core, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }

        var found: Set<String> = []
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            // A declaration, not a call: `package func linkEnded()` rather than `x.linkEnded()`. Comments are
            // excluded so that a doc mentioning the method does not read as one.
            let declares = source
                .split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.hasPrefix("//") && !$0.hasPrefix("///") && !$0.hasPrefix("*") }
                .contains { $0.contains("func linkEnded()") }
            if declares {
                found.insert(file.deletingPathExtension().lastPathComponent)
            }
        }
        return found
    }

    @Test("Every FacetCore module that resets on linkEnded is in main.swift's fan-out")
    func theFanOutIsComplete() throws {
        let resetters = try typesThatResetOnLinkEnded()

        // The premise. If this fails the scan has stopped finding anything and the rest of the test is vacuous,
        // which is the way a check like this fails open.
        #expect(resetters.count >= 3, "the scan found \(resetters.count) modules, so it has stopped working")

        let main = try String(
            contentsOf: Self.repositoryRoot.appendingPathComponent("Sources/FacetMac/main.swift"),
            encoding: .utf8
        )
        guard let list = main.range(of: "let linkEnders: [() -> Void] = ["),
              let close = main.range(of: "]", range: list.upperBound..<main.endIndex)
        else {
            Issue.record("main.swift no longer declares `linkEnders`, so nothing here can check it")
            return
        }
        let wired = String(main[list.upperBound..<close.lowerBound])

        for module in resetters.sorted() {
            // The instance is lower-camel of the type in `main.swift` for two of the three (`faceColours` for
            // `FaceColourSync` is the exception), so the name is matched loosely: what matters is that something
            // in the list mentions this module, not what it is called locally.
            let stem = module
                .replacingOccurrences(of: "Sync", with: "")
                .replacingOccurrences(of: "Ingestor", with: "")
            let head = String(stem.prefix(6))
            #expect(
                wired.lowercased().contains(head.lowercased()),
                """
                \(module) declares linkEnded() and nothing in main.swift's `linkEnders` mentions it. \
                A module holding per-link state that is never told the link ended stalls for the rest of the \
                launch, silently: see the comments on HistoryIngestor.linkEnded and FaceColourSync.linkEnded. \
                Add it to `linkEnders`.
                """
            )
        }
    }

    @Test("The fan-out has no entry for a module that no longer resets")
    func theFanOutHasNothingStale() throws {
        let main = try String(
            contentsOf: Self.repositoryRoot.appendingPathComponent("Sources/FacetMac/main.swift"),
            encoding: .utf8
        )
        // Three entries today. A stale one is a call to a method that no longer exists, so the compiler catches
        // that; what this catches is the list quietly growing duplicates or losing its shape.
        let entries = main
            .split(separator: "\n")
            .filter { $0.contains(".linkEnded,") }
        let resetters = try typesThatResetOnLinkEnded().count
        #expect(entries.count == resetters)
    }
}
