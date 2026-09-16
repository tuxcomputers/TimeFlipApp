import Foundation

/// One row of the App tab, written, read back, and reported on.
///
/// **The companion to `DeviceSettingWrite`, for the settings that are the app's own rather than the cube's.** There
/// is no device in this one and so no ordering to keep -- the table is the only thing being told -- but everything
/// else is the same shape and for the same reasons: the write is checked by reading it back, the surface adopts the
/// change only once the table has it, and a refused write puts the row back and says so.
///
/// **What each change writes is `AppSettingsRules.destination`'s**, which is where a control's value becomes a
/// setting name, a field and a stored type. Nothing here decides that; what it does is carry it out in the right
/// order and say what happened.
///
/// **The four requests are not this module's.** `debugDirectoryRequested`, `debugRevealRequested`,
/// `debugCopyRequested` and the five Google ones are gestures asking a *platform* for something -- a folder chooser,
/// a file manager, a browser -- and they write nothing on their own. `destination` answers `nil` for each, so they
/// arrive here as `.notASetting` and the surface that raised one deals with it.
@MainActor
package enum AppSettingWrite {
    /// What became of a change.
    package enum Outcome: Equatable {
        /// Written and read back. The surface may adopt it.
        case stored
        /// The table would not take it. The surface puts the row back and says so, under this title.
        case refused(title: String)
        /// Not a row at all: a request for something only a platform can do.
        case notASetting
    }

    /// Writes one change.
    ///
    /// - Returns: what to do about it, which is the surface's half. **Split that way rather than handed a pane**,
    ///   because the two platforms put a row back differently and neither difference is a decision: what is decided
    ///   here is whether the row may be adopted at all.
    package static func apply(
        _ change: AppSettingsChange,
        to settings: SettingStore,
        debugLog: DebugLog?
    ) -> Outcome {
        guard let (setting, field, value) = AppSettingsRules.destination(for: change) else { return .notASetting }
        let stored: Bool
        switch value {
        case let .flag(flag):
            stored = settings.write(setting, field: field, flag)
        case let .number(number):
            stored = settings.write(setting, field: field, number)
        case let .text(text):
            stored = settings.write(setting, field: field, text)
        }
        debugLog?.record(
            .field,
            "App setting \(setting).\(field) -> \(value)\(stored ? "" : " REFUSED, the table does not hold it")"
        )
        return stored ? .stored : .refused(title: AppSettingsRules.title(for: change))
    }
}
