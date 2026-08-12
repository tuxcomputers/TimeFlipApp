import Foundation

/// Which database this launch is recording into.
///
/// Read from the `db_type` setting rather than inferred from the file's name. The app always opens
/// `appdata.sqlite`, and pointing a session at a throwaway copy is a matter of what that name resolves
/// to -- so the path says nothing, while the row travels with the file itself and stays right however
/// the file was reached.
enum DatabaseEnvironment: String, CaseIterable {
    /// The real database, holding real timings.
    case production
    /// A copy, so a test run cannot write into the real one.
    case test

    /// Reads `db_type`.
    ///
    /// Returns `nil` for anything unexpected -- no row, a value naming neither environment, a database
    /// that would not open -- rather than falling back to `.production`. A default here would answer
    /// "which database am I writing to" with the reassuring option at exactly the moment the answer is
    /// unknown, and the whole point of asking is to catch the case where it isn't the one you assumed.
    @MainActor
    static func read(from settings: SettingReader) -> DatabaseEnvironment? {
        guard let type = settings.string("db_type", field: "type") else { return nil }
        return DatabaseEnvironment(rawValue: type.lowercased())
    }
}
