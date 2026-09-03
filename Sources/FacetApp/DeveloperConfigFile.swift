import Foundation

/// `config.json`, the app's one piece of state that is not a row: a PIN the Keychain would not take.
///
/// **Why a file and not the `setting` table.** The PIN is a credential, and the archive kept it out of its own
/// database for the same reason it kept the Google client secret out: a database is copied around, switched between
/// production and test (`scripts/switch-database.sh`), and handed to a test run that rebuilds it from the DDL. A cube
/// does not know which database is in play, so a PIN that lives in one is a PIN that a database swap loses -- and a
/// lost PIN is a cube nobody can log into. This file sits beside the databases and outlives all of them.
///
/// That is the exception `CLAUDE.md` asks to be named at the point it is taken, and it is narrow: it is one value,
/// it is read at the moment it is needed and never held, and the read-back after a write is the same check the
/// Settings window does against the table.
///
/// **The archive's file, the archive's key.** `PIN`, in
/// `~/Library/Application Support/Facet/config.json` (`Archive/TimeFlipApp/DeveloperConfigStore.swift`, which used
/// `TimeFlip` for the folder as the app was called then). Copied as it stands rather than renamed, because a dev
/// machine's file already holds the PIN of the cube this rebuild is tested against and a new name would strand it.
///
/// **Massaged in one place: what a write does to the rest of the file.** The archive encoded a three-field `Codable`
/// payload over the whole file, which was safe only because those three fields were the whole file. This build reads
/// its Google credentials from somewhere else entirely (`GoogleCredentials.resolve`), so the same shape here would
/// silently drop a `client_id` and `client_secret` that a developer's file still carries. It merges into whatever is
/// there instead, and knows about exactly one key.
struct DeveloperConfigFile {
    /// The archive's name for it, and the one an existing dev machine's file already uses.
    static let pinKey = "PIN"

    let url: URL

    /// The file.
    ///
    /// **There is one use for it and only one**: somewhere to put a cube's PIN when the Keychain would not take it
    /// (`DevicePINSource.record`). That is the difference between a failed Keychain write and a cube nobody can log
    /// into again -- the PIN is on the hardware either way, so the only question is whether this app can still name
    /// it.
    ///
    /// It is written in that one case, read on the next launch, and cleared as soon as the Keychain accepts the
    /// value (`DevicePINSource.reconcile`), so it exists only for as long as the fault does.
    static var atStandardPath: DeveloperConfigFile {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return DeveloperConfigFile(
            url: base.appendingPathComponent("Facet", isDirectory: true).appendingPathComponent("config.json")
        )
    }

    /// The PIN the file names, or `nil` if it names none, names one the password characteristic could not hold, or
    /// is not readable JSON at all.
    ///
    /// **A malformed file is treated as an empty one**, not as an error to raise. What follows a `nil` here is the
    /// vendor default being tried on its own, which is exactly what should happen when nothing is known about the
    /// cube -- and the alternative, refusing to connect because a JSON file is broken, would be a lockout caused by
    /// a text editor.
    func pin() -> String? {
        guard let pin = contents()?[Self.pinKey] as? String, DeviceLoginRules.isWellFormed(pin) else { return nil }
        return pin
    }

    /// Writes `pin` into the file, leaving every other key in it alone, and answers whether the file now holds it.
    ///
    /// **The answer comes from reading it back**, not from the write reporting success, which is `CLAUDE.md`'s rule
    /// about writes to the database applied to the one value that is not in it. A write that silently did nothing
    /// would leave the app believing it knows a PIN that only the cube now has.
    @discardableResult
    func record(pin: String) -> Bool {
        var contents = self.contents() ?? [:]
        contents[Self.pinKey] = pin
        guard let data = try? JSONSerialization.data(
            withJSONObject: contents, options: [.prettyPrinted, .sortedKeys]
        ) else {
            return false
        }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        // **Deliberately not `.atomic`, and this is the archive's comment kept because the reason has not changed.**
        // An atomic write replaces whatever sits at the path by rename, which severs a symlink or a hard link -- and
        // this file is very often a link to a checkout on a developer's machine. Writing in place opens the existing
        // path and overwrites its bytes, so both survive.
        guard (try? data.write(to: url)) != nil else { return false }
        return self.pin() == pin
    }

    /// Takes the PIN out of the file, leaving every other key in it alone, and answers whether it is gone.
    ///
    /// **What happens once the Keychain has the value** (`DevicePINSource.reconcile`): the fallback existed because
    /// the Keychain refused a write, and a copy of a live credential in a plain file is not something to leave lying
    /// about once it is no longer the only one.
    ///
    /// **`true` when there was nothing to remove**, for the reason `GoogleTokenStore.clear` gives: the caller asked
    /// for the file not to name a PIN, and it does not. A file that cannot be read is in that state too -- there is
    /// no PIN in it to act on.
    @discardableResult
    func clearPIN() -> Bool {
        guard var contents = self.contents(), contents[Self.pinKey] != nil else { return true }
        contents.removeValue(forKey: Self.pinKey)
        guard let data = try? JSONSerialization.data(
            withJSONObject: contents, options: [.prettyPrinted, .sortedKeys]
        ) else {
            return false
        }
        // Not `.atomic`, for the reason `record` gives: this path is very often a link into a checkout.
        guard (try? data.write(to: url)) != nil else { return false }
        return pin() == nil
    }

    private func contents() -> [String: Any]? {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }
        return object
    }
}
