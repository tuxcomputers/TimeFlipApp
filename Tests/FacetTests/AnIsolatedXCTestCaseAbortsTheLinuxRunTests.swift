import Foundation
import Testing

/// Checks that no `XCTestCase` this platform builds is `@MainActor`, anywhere in the file.
///
/// **Because it is a crash and not a failure.** Linux discovers tests by reflecting over the method type, and an
/// isolated method does not cast:
///
///     Could not cast '(FacetTests.QuitSequenceTests) -> @MainActor () throws -> ()'
///                 to '(FacetTests.QuitSequenceTests) -> () throws -> ()'
///
/// One such class aborts the whole test executable with SIGABRT **before a single test runs**, so the price is
/// never the file that caused it -- on 2026-09-11 three of them cost all 671 XCTest tests, and the run reported
/// nothing that could be read as a clue. `docs/linux-port.md` records the measurement under *`@MainActor` blocks
/// XCTest*; this is the part that keeps it from coming back.
///
/// **It exists because the fix does not stick on its own.** The suite was cleared of isolated `XCTestCase`s on
/// 2026-09-09 and had three again by 2026-09-10, each written on the Mac, where nothing complains: the attribute
/// is free there and the file crashes a machine the author is not sitting at. So this fails on both platforms,
/// which is the only place it is worth failing.
///
/// **The two ways out, and which to take.** If the subject really is `@MainActor`, make the file a
/// `@Suite @MainActor` swift-testing suite -- `QuitSequenceTests` and `CubeLockTests` are what that looks like,
/// and `docs/linux-port.md` has the conversion table. If it is not, delete the attribute: two of the three found
/// on 2026-09-11 were carrying isolation left behind by a subject that had moved into the core and stopped
/// touching AppKit.
///
/// **What it deliberately does not check**: a file `Package.swift` excludes from the Linux build. Those are the
/// AppKit suites, whose subjects are `@MainActor` because `NSView` is, and they are never loaded here. The
/// exclusion list is read from the manifest rather than copied, so a file coming off it is checked from that
/// moment without anybody remembering to say so here.
@Suite
struct AnIsolatedXCTestCaseAbortsTheLinuxRunTests {
    private static var root: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Tests/FacetTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // the root
    }

    private static var suiteDirectory: URL {
        root.appendingPathComponent("Tests/FacetTests", isDirectory: true)
    }

    /// The file names in `Package.swift`'s `platformBoundTests`, read from the manifest itself.
    ///
    /// **Read rather than copied**, because a second copy of this list is the hazard `CLAUDE.md` opens with: the
    /// manifest's is what SwiftPM acts on, and a copy here would go stale in the direction that matters -- a file
    /// coming off the exclusion list and not being checked.
    private static func excludedFromTheLinuxBuild() throws -> Set<String> {
        let manifest = try String(contentsOf: root.appendingPathComponent("Package.swift"), encoding: .utf8)
        guard let start = manifest.range(of: "let platformBoundTests = ["),
              let end = manifest.range(of: "]", range: start.upperBound ..< manifest.endIndex)
        else { return [] }

        var names: Set<String> = []
        for line in manifest[start.upperBound ..< end.lowerBound].split(separator: "\n") {
            let quoted = line.split(separator: "\"")
            guard quoted.count > 1 else { continue }
            names.insert(String(quoted[1]))
        }
        return names
    }

    @Test("No XCTestCase built on Linux is isolated to the main actor")
    func noXCTestCaseBuiltHereIsIsolated() throws {
        let excluded = try Self.excludedFromTheLinuxBuild()
        // The premise, twice over. A scan that found no files, or a manifest whose list stopped parsing, would
        // pass this test by finding nothing to complain about.
        #expect(!excluded.isEmpty, "the exclusion list did not parse out of Package.swift, so this check is blind")

        let files = try FileManager.default
            .contentsOfDirectory(at: Self.suiteDirectory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        #expect(!files.isEmpty, "the scan found no test sources at all, so it has stopped working")

        for file in files {
            let name = file.lastPathComponent
            guard !excluded.contains(name) else { continue }

            // Prose may name what the code may not: the three files fixed on 2026-09-11 all explain in a comment
            // what they used to carry, and a check that read those would fail on its own cure.
            let code = try String(contentsOf: file, encoding: .utf8)
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.hasPrefix("//") }

            guard code.contains(where: { $0.contains("XCTestCase") }) else { continue }
            guard let isolated = code.firstIndex(where: { $0.hasPrefix("@MainActor") }) else { continue }

            Issue.record(
                """
                \(name) is an XCTestCase and says `\(code[isolated])`, which aborts the whole test executable on \
                Linux at load time -- taking every other suite with it, before anything runs. Either make it a \
                `@Suite @MainActor` swift-testing suite, which handles isolation on both platforms \
                (`QuitSequenceTests` is the worked example), or delete the attribute if the subject does not \
                actually need it. See docs/linux-port.md, "`@MainActor` blocks XCTest, and swift-testing fixes it".
                """
            )
        }
    }
}
