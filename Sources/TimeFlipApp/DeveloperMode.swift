import Foundation

/// The developer flag, and the dev-only console logging it gates.
///
/// In the archived app this lived in `DeveloperConfigStore.swift` and bundled two independent things
/// under one switch: this logging, and reading Google/device credentials from `config.json` instead of
/// the Keychain (`docs/TODO-devmode.md` records that they are separable and should be decided
/// separately). Only the flag and the logging are here; the credential store returns with the code
/// that needs credentials.
///
/// Two pieces from the archive are deliberately **not** here yet, because what they attach to does not
/// exist:
///
/// - `isDebugSettingEnabled`, set at startup from the database's `debug` setting, which is how debug
///   output is turned off without a rebuild. The seeded setting is already in `011_setting.sql`; the
///   loader that reads it is not written.
/// - `logSink`, which also wrote every message into the `debug_log` table. That table is seeded but
///   nothing writes to it yet, and the test harness reads *rows*, not console text -- so until the
///   sink is back, a script cannot confirm anything from these messages.
enum DeveloperMode {
    /// The dev flag. Compile-time, deliberately: it decides whether dev-only behaviour exists at all,
    /// as distinct from the database setting above, which decides whether it is switched on today.
    static let isEnabled = true

    /// Identifies the subsystem a dev-only message comes from. `bracketed` right-pads each tag's name
    /// to the width of the longest case, so console lines stay aligned however they interleave --
    /// `[database]` beside `[click   ]`. The width is derived rather than written down, so adding a
    /// longer case re-pads every existing tag automatically and no other case needs touching.
    enum DebugTag: String, CaseIterable {
        /// Bringing the schema up at startup: what was applied, and to which file.
        case database
        /// Clicks on the status item, and which half they landed on.
        case click
        /// Selections from the dropdown.
        case menu

        private static let width = allCases.map(\.rawValue.count).max() ?? 0

        /// Internal rather than fileprivate, so the alignment can be asserted without launching the
        /// app. It is a convention the project states explicitly (see the root `CLAUDE.md` on debug
        /// messages), and console output only reaches a terminal when the process exits normally --
        /// which, now that Quit is the only exit, makes eyeballing it the expensive way to check.
        var bracketed: String {
            "[\(rawValue.padding(toLength: Self.width, withPad: " ", startingAt: 0))]"
        }
    }

    private static let debugTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        formatter.timeZone = .current
        // POSIX locale so the 24-hour format holds whatever the machine's region does to
        // `HH` -- a dev build on a 12-hour locale should still log 13:25:38.
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    /// Prints a dev-only console message, led by a zero-padded 24-hour local time and the tag's padded
    /// name -- `13:25:38 [database] applied 12 file(s)`.
    ///
    /// `message` is an autoclosure so the interpolation is never evaluated when the flag is off: a
    /// disabled debug line should cost nothing, not merely print nothing.
    static func debugPrint(_ tag: DebugTag, _ message: @autoclosure () -> String) {
        guard isEnabled else { return }
        print("\(debugTimeFormatter.string(from: Date())) \(tag.bracketed) \(message())")
    }
}
