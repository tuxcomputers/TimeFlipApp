import Foundation
import Testing

/// Checks that every file `Package.swift` keeps out of the Linux build actually touches a platform.
///
/// **The list is debt, and debt that nobody is billed for stops being paid.** `platformBoundTests` exists
/// because a suite genuinely needs AppKit, CoreBluetooth or a `FacetMac` type, and the ports remodel keeps
/// falsifying that one file at a time: a decision moves into `FacetCore`, its tests stop touching the platform,
/// and the entry stays behind because nothing asks it to leave. A file sitting there needlessly is a suite that
/// silently does not run on Linux, which is the one failure this whole exercise is about.
///
/// **Two were found by hand in two days, which is the argument for a machine doing it.** `GoogleOAuthRulesTests`
/// came off on 2026-09-10 and `BLETraceTests` on 2026-09-11, each spotted by somebody reading the list and
/// wondering. `docs/architecture-review-2026-09.md` proposed exactly this check under candidate 7 and recorded
/// that it was not built, being premature while the port was still moving. The port is still moving; that turns
/// out to be the reason to have it rather than the reason to wait.
///
/// **What counts as touching a platform**, and it is deliberately generous, because a false failure here costs
/// somebody an argument with a test that is wrong:
///
/// - any `NS`-prefixed name, which is AppKit and Foundation's older half;
/// - any `CB`-prefixed name, which is CoreBluetooth;
/// - any type `Sources/FacetMac` declares, read from the sources rather than listed here.
///
/// **Comments are stripped before looking.** Three files fixed on 2026-09-11 explain in prose what they used to
/// carry, and a check that read those would pass on the strength of the cure being described.
///
/// **It cannot prove the converse**, and does not try. A file that mentions `NSView` once in a helper it could
/// live without still passes, so this catches a suite that has drifted clear of the platform entirely rather
/// than one that is merely close. That is the cheap half, and it is the half that has actually gone wrong.
@Suite
struct EveryLinuxExclusionEarnsItsPlaceTests {
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
    /// **Read rather than copied**, for the reason its sibling gate gives: the manifest's list is what SwiftPM
    /// acts on, and a copy here would go stale in the direction that matters.
    private static func excludedFromTheLinuxBuild() throws -> [String] {
        let manifest = try String(contentsOf: root.appendingPathComponent("Package.swift"), encoding: .utf8)
        guard let start = manifest.range(of: "let platformBoundTests = ["),
              let end = manifest.range(of: "]", range: start.upperBound ..< manifest.endIndex)
        else { return [] }

        var names: [String] = []
        for line in manifest[start.upperBound ..< end.lowerBound].split(separator: "\n") {
            let quoted = line.split(separator: "\"")
            guard quoted.count > 1 else { continue }
            names.append(String(quoted[1]))
        }
        return names
    }

    /// Every type `FacetMac` declares, so this does not hold a list of them that could go stale.
    private static func typesFacetMacDeclares() throws -> Set<String> {
        let directory = root.appendingPathComponent("Sources/FacetMac", isDirectory: true)
        let files = try FileManager.default
            .contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }

        var names: Set<String> = []
        let keywords = ["final class ", "class ", "struct ", "enum ", "protocol ", "actor "]
        for file in files {
            for line in try String(contentsOf: file, encoding: .utf8).split(separator: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                // **Comments are dropped here too, and skipping this made the whole check useless.** Prose in
                // `FacetMac` says "the main actor" often, which put the next word after it into the set: `from`
                // was in there, and a one-word junk entry matches nearly every file, so every exclusion looked
                // justified. Found on 2026-09-11 by checking the gate against drift that had really happened
                // rather than against drift invented for the test.
                guard !trimmed.hasPrefix("//") else { continue }
                guard let keyword = keywords.first(where: { trimmed.contains($0) }) else { continue }
                guard let after = trimmed.range(of: keyword) else { continue }
                let rest = trimmed[after.upperBound...]
                let name = rest.prefix { $0.isLetter || $0.isNumber || $0 == "_" }
                // A Swift type is capitalised, and everything here is. Anything else came from prose.
                guard let first = name.first, first.isUppercase else { continue }
                names.insert(String(name))
            }
        }
        return names
    }

    /// A file's lines with comment-only ones dropped, so prose about a platform does not read as use of one.
    private static func code(of file: URL) throws -> String {
        try String(contentsOf: file, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.hasPrefix("//") }
            .joined(separator: "\n")
    }

    @Test("Every file kept out of the Linux build still touches a platform")
    func everyExclusionStillTouchesAPlatform() throws {
        let excluded = try Self.excludedFromTheLinuxBuild()
        // The premise. A list that stopped parsing would pass this by finding nothing to complain about.
        #expect(!excluded.isEmpty, "the exclusion list did not parse out of Package.swift, so this check is blind")

        let macTypes = try Self.typesFacetMacDeclares()
        #expect(macTypes.count > 20, "the FacetMac scan found \(macTypes.count) types, so it has stopped working")

        for name in excluded {
            let file = Self.suiteDirectory.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: file.path) else {
                Issue.record(
                    """
                    Package.swift keeps \(name) out of the Linux build and there is no such file. An entry naming \
                    nothing is the same drift as an entry that no longer needs to be there: delete the line.
                    """
                )
                continue
            }

            let body = try Self.code(of: file)
            if body.range(of: #"\bNS[A-Z]"#, options: .regularExpression) != nil { continue }
            if body.range(of: #"\bCB[A-Z]"#, options: .regularExpression) != nil { continue }
            if macTypes.contains(where: { body.range(of: "\\b\($0)\\b", options: .regularExpression) != nil }) {
                continue
            }

            Issue.record(
                """
                \(name) is kept out of the Linux build and names no platform type: no `NS`, no `CB`, and nothing \
                `Sources/FacetMac` declares. Either it drifted clear when its subject moved into `FacetCore`, in \
                which case take it off `platformBoundTests` in Package.swift and drop any `@testable import \
                FacetMac` it is still carrying, or it needs the platform in some way this cannot see, in which \
                case say how in a comment so the next person does not have this argument again.
                """
            )
        }
    }
}
