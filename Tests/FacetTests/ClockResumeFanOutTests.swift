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
/// **`Sources/FacetLinux/main.swift` is deliberately not read yet**, which is a gap rather than a decision.
/// That root resumes both clocks inline in `onLoginEnded` and so has never had this fault, but it carries no named
/// list for this test to find. Adopting one is asked for in `docs/handover-linux.md`, because it is a change to a file
/// the Mac cannot compile and editing this side's sources blind is what handover items 23 and 24 cost in the other
/// direction. The day it lands, this test takes a second path rather than a second copy -- the same note
/// `LinkEndedFanOutTests` carries.
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

    /// The contents of `clocksResumedOnLink` in the macOS composition root, or `nil` if it has gone.
    private func macFanOut() throws -> String? {
        let main = try String(
            contentsOf: Self.repositoryRoot.appendingPathComponent("Sources/FacetMac/main.swift"),
            encoding: .utf8
        )
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

        guard let wired = try macFanOut() else {
            Issue.record("main.swift no longer declares `clocksResumedOnLink`, so nothing here can check it")
            return
        }

        for module in resumable.sorted() {
            // The instance is lower-camel of the type for one of the two and shortened for the other
            // (`dailyLimit` for `DailyLimitWatch`), so the match is on a stem: what matters is that something in
            // the list mentions this module, not what it is called locally.
            let stem = module.replacingOccurrences(of: "Watch", with: "")
            let head = String(stem.prefix(6))
            #expect(
                wired.lowercased().contains(head.lowercased()),
                """
                \(module) declares resumeIfStopped() and nothing in main.swift's `clocksResumedOnLink` mentions \
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
        let main = try String(
            contentsOf: Self.repositoryRoot.appendingPathComponent("Sources/FacetMac/main.swift"),
            encoding: .utf8
        )
        // A list nothing iterates is the same fault wearing a name, and it would pass the test above.
        #expect(
            main.contains("for resume in clocksResumedOnLink"),
            "`clocksResumedOnLink` is declared and never iterated, so no clock is resumed when a cube arrives"
        )
        // And it has to hang off the link coming up rather than somewhere that happens to run. `onCubeReady` is the
        // moment: the characteristics are discovered and `connection` is already written, which is what
        // `HistoryTimer.hasSomethingToFollow` reads.
        guard let ready = main.range(of: "radio.onCubeReady = {"),
              let close = main.range(of: "\n}", range: ready.upperBound..<main.endIndex)
        else {
            Issue.record("main.swift no longer wires `radio.onCubeReady`, so nothing here can check where it runs")
            return
        }
        #expect(
            main[ready.upperBound..<close.lowerBound].contains("clocksResumedOnLink"),
            """
            `clocksResumedOnLink` is iterated somewhere other than `radio.onCubeReady`. The clocks have to come \
            back when the link comes up: earlier and `connection` is not written yet, so `hasSomethingToFollow` \
            reads false and the resume does nothing at all.
            """
        )
    }

    @Test("The fan-out has no entry for a module that no longer stands its clock down")
    func theFanOutHasNothingStale() throws {
        guard let wired = try macFanOut() else {
            Issue.record("main.swift no longer declares `clocksResumedOnLink`, so nothing here can check it")
            return
        }
        let entries = wired
            .split(separator: "\n")
            .filter { $0.contains(".resumeIfStopped") }
        #expect(entries.count == (try typesWithAResumableClock().count))
    }
}
