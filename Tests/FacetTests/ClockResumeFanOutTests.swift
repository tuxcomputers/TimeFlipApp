@testable import FacetCore
import Foundation
import Testing

/// Checks that every module which stands its own clock down is started again when a cube arrives.
///
/// **The mirror of `LinkEndedFanOutTests`, and the same tactic for the same reason.** That one checks what a link
/// *ending* has to let go of; this one checks what a link *coming up* has to put back on its feet. Both lists live in
/// `main.swift`, both are three or fewer lines, and both fail silently and only sometimes when a line is missing.
///
/// **This exists because a line was missing for months.** `HistoryTimer.start()` stands down when
/// `hasSomethingToFollow()` is false, which is every launch whose cube is out of range at the time, and on macOS
/// `resumeIfStopped` was reached only from `settingsWindow.onTimingChanged` -- a rename, a limit raised, a retire, the
/// Timing column, a face given a category, the manual toggle. **None of those is a cube connecting.** So a Mac launch
/// that found its cube a minute later had a periodic history fetch that was dead for the rest of the session.
///
/// **Why nobody noticed, which is the part worth keeping.** The timer is a safety net rather than the mechanism:
/// `onCubeReady` fetches once when the link comes up and `onFace` fetches on every turn, so history still arrived and
/// the only thing lost was `fetch_history_interval_seconds` meaning anything. A fault that costs nothing visible is a
/// fault that stays, which is exactly the class this file is for.
///
/// **It was found by the other machine**, reading `Sources/FacetMac/main.swift` from Linux and writing it up as item
/// 28 of `docs/handover-mac.md`, where the Linux composition root does the same job on `onLoginEnded` and visibly
/// works. Two composition roots is the cheapest code review this project has, and it should not be the only one.
///
/// ## What this checks and what it cannot
///
/// It reads the sources, because the type system will not answer "is anything missing" -- the same argument
/// `LinkEndedFanOutTests` and `PlatformBlindCoreTests` make, and the same one `scripts/check_interactive_checklists.sh`
/// makes for the scripted suite. Registering conformers of a protocol would not help: Swift will not enumerate them,
/// so the registry would be a hand-written list and forgetting a line in it is exactly as silent.
///
/// **It does not check that resuming does the right thing**, which is each module's own suite, and it does not check
/// the other moments a clock is resumed. `settingsWindow.onTimingChanged` and `historyIngestor.onChanged` are both
/// real and both stay: a clock has more than one reason to come back, and this list is only the cube-arrival one.
///
/// **Both composition roots are read, as of 2026-09-18**, which is what this file said it would do the day the
/// Linux list landed: a second path rather than a second copy. Every assertion below runs against each root, and
/// what differs between them is one string -- **which callback the list is iterated from** -- which is a real
/// difference rather than a style:
///
/// - The Mac's has to be `onCubeReady`, because `connection` is not written until then and
///   `HistoryTimer.hasSomethingToFollow` reads that row: a resume any earlier does nothing at all.
/// - Linux's is `onLoginEnded`, and may be, because `CubeReports.loginEnded` writes that row earlier in the same
///   callback. It is the earliest moment that works, and earlier is what a clock wants.
///
/// The Mac asked for the list and left the callback to the other machine (`docs/handover-linux.md` item 37,
/// answered 2026-09-18). So the moment is per root here, and a root that moved its list somewhere neither name
/// covers fails.
@Suite
struct ClockResumeFanOutTests {
    /// The repository root, from this file's own path, so nothing depends on the working directory a runner uses.
    private static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Tests/FacetTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // the root
    }

    /// Every type in `FacetCore` that declares `func resumeIfStopped()`.
    ///
    /// A declaration, not a call, and comments are excluded so that a doc mentioning the method does not read as one.
    private func typesWithAResumableClock() throws -> Set<String> {
        let core = Self.repositoryRoot.appendingPathComponent("Sources/FacetCore", isDirectory: true)
        let files = try FileManager.default.contentsOfDirectory(at: core, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }

        var found: Set<String> = []
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            let declares = source
                .split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.hasPrefix("//") && !$0.hasPrefix("///") && !$0.hasPrefix("*") }
                .contains { $0.contains("func resumeIfStopped()") }
            if declares {
                found.insert(file.deletingPathExtension().lastPathComponent)
            }
        }
        return found
    }

    /// One composition root: where its `main.swift` is, which callback its list has to be iterated from, and how
    /// that callback's block ends in that file.
    private struct Root {
        let target: String
        /// The callback the fan-out belongs in, as it is written in that file.
        let callback: String
        /// The line that closes that callback. Top level on the Mac, one level in on Linux, where the radio's
        /// callbacks are wired inside `if let radio {`.
        let blockEnd: String
        /// Why it is that callback, said in the failure so nobody has to come and read this file.
        let because: String

        var path: String { "Sources/\(target)/main.swift" }
    }

    /// **Both roots, and each with its own moment.** Named once so every test below runs against the pair.
    private static let roots = [
        Root(
            target: "FacetMac",
            callback: "radio.onCubeReady = {",
            blockEnd: "\n}",
            because: "earlier and connection is not written yet, so hasSomethingToFollow reads false"
        ),
        Root(
            target: "FacetLinux",
            callback: "radio.onLoginEnded = {",
            blockEnd: "\n    }",
            because: "CubeReports.loginEnded writes connection earlier in that same callback, so this root may "
                + "resume at the login rather than waiting for the characteristics"
        ),
    ]

    private func source(of root: Root) throws -> String {
        try String(contentsOf: Self.repositoryRoot.appendingPathComponent(root.path), encoding: .utf8)
    }

    /// The contents of `clocksResumedOnLink` in one root, or `nil` if it has gone.
    private func fanOut(in root: Root) throws -> String? {
        let main = try source(of: root)
        guard let list = main.range(of: "let clocksResumedOnLink: [() -> Void] = ["),
              let close = main.range(of: "]", range: list.upperBound..<main.endIndex)
        else { return nil }
        return String(main[list.upperBound..<close.lowerBound])
    }

    @Test("Every FacetCore module with a resumable clock is in main.swift's cube-arrival fan-out")
    func theFanOutIsComplete() throws {
        let resumable = try typesWithAResumableClock()

        // The premise. A scan finding nothing is how a check like this fails open, and it has known members.
        #expect(
            resumable.count >= 2,
            "the scan found \(resumable.count) modules with resumeIfStopped(), so it has stopped working"
        )

        for root in Self.roots {
            guard let wired = try fanOut(in: root) else {
                Issue.record("\(root.path) no longer declares clocksResumedOnLink, so nothing here can check it")
                continue
            }
            expectEveryClock(resumable, isIn: wired, of: root)
        }
    }

    /// The completeness check for one root.
    private func expectEveryClock(_ resumable: Set<String>, isIn wired: String, of root: Root) {
        for module in resumable.sorted() {
            // The instance is lower-camel of the type for one of the two and shortened for the other
            // (`dailyLimit` for `DailyLimitWatch`), so the match is on a stem: what matters is that something in
            // the list mentions this module, not what it is called locally.
            let stem = module.replacingOccurrences(of: "Watch", with: "")
            let head = String(stem.prefix(6))
            #expect(
                wired.lowercased().contains(head.lowercased()),
                """
                \(module) declares resumeIfStopped() and nothing in \(root.path)'s fan-out mentions \
                it. A clock that stands itself down when there is nothing to follow, and is never started again \
                when a cube arrives, is dead for the rest of that launch -- silently, and only on the launches \
                where the cube was out of range at startup. That is docs/handover-mac.md item 28, which is what \
                this test exists to stop happening twice. Add it to `clocksResumedOnLink`.
                """
            )
        }
    }

    @Test("The cube-arrival fan-out is actually called, and on the link coming up")
    func theFanOutIsReached() throws {
        for root in Self.roots {
            let main = try source(of: root)
            // A list nothing iterates is the same fault wearing a name, and it would pass the test above.
            #expect(
                main.contains("for resume in clocksResumedOnLink"),
                "\(root.path) declares clocksResumedOnLink and never iterates it, so no clock is resumed"
            )
            // And it has to hang off the link coming up rather than somewhere that happens to run.
            guard let opens = main.range(of: root.callback),
                  let close = main.range(of: root.blockEnd, range: opens.upperBound..<main.endIndex)
            else {
                Issue.record("\(root.path) no longer wires \(root.callback), so nothing here can check the moment")
                continue
            }
            #expect(
                main[opens.upperBound..<close.lowerBound].contains("clocksResumedOnLink"),
                """
                \(root.path) iterates clocksResumedOnLink somewhere other than \(root.callback). The clocks have \
                to come back when the link comes up, and for this root that callback is the moment: \(root.because).
                """
            )
        }
    }

    @Test("The fan-out has no entry for a module that no longer stands its clock down")
    func theFanOutHasNothingStale() throws {
        let resumable = try typesWithAResumableClock().count
        for root in Self.roots {
            guard let wired = try fanOut(in: root) else {
                Issue.record("\(root.path) no longer declares clocksResumedOnLink, so nothing here can check it")
                continue
            }
            let entries = wired
                .split(separator: "\n")
                .filter { $0.contains(".resumeIfStopped") }
            #expect(
                entries.count == resumable,
                """
                \(root.path)'s fan-out has \(entries.count) entries against \(resumable) modules that stand a \
                clock down. An entry for a module that no longer has one is a line nobody will delete, and the \
                count is what notices.
                """
            )
        }
    }
}
