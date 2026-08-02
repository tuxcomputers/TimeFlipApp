import Foundation

/// The decisions the Device tab's rename makes, with none of the SwiftUI it makes them in --
/// the same seam `CategoryEditRules` is for the Categories tab.
///
/// Worth separating here for a reason particular to this field: the limits are the **device's**,
/// not the app's. `TimeFlipBLEDevice.setDeviceName` refuses a name that is empty, not ASCII, or
/// over 18 symbols by returning false, and a false is nearly silent -- a log line and a name that
/// did not change. Deciding what is acceptable in a pure function means the field can refuse the
/// same things up front, and means those limits can be tested without a device.
enum DeviceNameRules {

    /// The device's own ceiling, not a display choice. The `0x15` entry in
    /// `docs/TimeFlip2 BLE Protocol v4.3.md` reads "name (18 symbols MAX. ASCII coding)", the
    /// command carrying a single length byte ahead of the name.
    ///
    /// Note the device's own read-back is wider: `0x2A00` is a 20-byte characteristic. Only the
    /// write is capped at 18, so a name arriving from elsewhere can be longer than anything this
    /// app is able to set.
    ///
    /// Declared here rather than on the driver, and `TimeFlipBLEDevice.maximumDeviceNameLength`
    /// now defers to it, so the field and the write cannot come to disagree about what fits. It
    /// has to live somewhere nonisolated to be usable from both: the driver is `@MainActor`, which
    /// a plain rules type cannot read a default value from.
    static let maximumLength = 18

    /// What the field is allowed to hold while it is being typed: **length only**.
    ///
    /// The limit is enforced as a keystroke stops landing, because a length is something the field
    /// can show honestly -- what is on screen is what will be written, and there is nothing to
    /// explain.
    ///
    /// Characters are deliberately **not** filtered here, even though the device takes only ASCII.
    /// Silently swallowing an emoji as it is typed looks like a broken keyboard: the character
    /// simply never appears and nothing says why. Letting it land and refusing it at submit, with
    /// an alert that names the reason, is the difference between the app seeming broken and the
    /// app telling the user what the device can do. `renameDecision` is where that refusal happens.
    ///
    /// Truncation counts characters. For a name that goes on to pass the ASCII check that is the
    /// same count the device sees in bytes; one that does not is refused rather than written, so
    /// the two counts can never disagree on anything actually sent.
    static func truncatedInput(_ typed: String) -> String {
        String(typed.prefix(maximumLength))
    }

    /// What a submitted name should do.
    ///
    /// Surrounding whitespace goes: it is invisible on the Device tab and in a scan list, so a name
    /// that differs from the current one only by a trailing space would spend a BLE write to
    /// produce no visible change. Interior spaces are kept -- "Solid cube" is a reasonable name.
    ///
    /// The character check is the one the user actually meets: an emoji or an accent reaches this
    /// point, because the field does not strip it, and gets refused with a reason.
    ///
    /// **The length check is deliberately repeated here**, even though `truncatedInput` has already
    /// held the field to 18 and the driver refuses an over-long name anyway. This one checks rather
    /// than truncates: a name arriving over the limit is refused and said so, because quietly
    /// writing its first 18 characters would name the device something nobody asked for. From the
    /// field it should be unreachable, which is the point -- it stands between the device and a
    /// paste path that outruns the truncation, or any future caller that does not come through this
    /// field at all.
    static func renameDecision(typed: String, current: String?) -> DeviceRenameDecision {
        let name = typed.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, name != current else { return .ignore }
        guard name.allSatisfy(isWritable) else { return .refuse(.unwritableCharacters) }
        guard name.count <= maximumLength else { return .refuse(.tooLong(count: name.count)) }
        return .write(name)
    }

    // MARK: - What the user sees after a rename

    /// What to tell the user once a rename has gone out, and why they are told anything at all.
    ///
    /// The rename does take effect, but for a while nothing looks like it did, in two separate
    /// ways, both measured rather than inferred (see `docs/timeflip2-firmware-observations.md`):
    ///
    /// - The name in the device's advertisements never changes at all. A Bluetooth scan, in this
    ///   app or any other, goes on listing the cube under its original TimeFlip name permanently.
    /// - The name it reports once connected (`0x2A00`, the GAP Device Name) is not pushed to a
    ///   connected Mac, only read at connect time, so the old name can survive a reconnect. A cube
    ///   renamed to `Plopper` reported `Dibby` on the next connect and `Plopper` only on the one
    ///   after that.
    ///
    /// Without saying this, the user renames the device, goes looking for the new name in a scan,
    /// finds the old one and reasonably concludes the rename silently failed and that this app
    /// broke it. So the notice leads with the rename having worked, and attributes the lag, for
    /// the same reason `DeviceNameProblem` attributes its limits rather than just stating them.
    ///
    /// The attribution is worded to match what is actually established. The unchanging advertised
    /// name is squarely the device's. The stale reported name is the device offering no way to be
    /// told a name changed, plus macOS caching what it last read, and there is no way to separate
    /// those two from a Mac -- so it is described as something the app cannot change rather than
    /// pinned on the firmware alone.
    static func renameLagNotice(newName: String, previousName: String?) -> String {
        let stillReported = previousName.map { "“\($0)”" } ?? "the old name"
        return """
        Renamed to “\(newName)”. The device has taken the name, but its firmware goes on \
        advertising the original TimeFlip name in a Bluetooth scan, and macOS can keep reporting \
        \(stillReported) for a reconnect or two before it catches up. Neither is something this \
        app can change. To refresh it now, use Forget Device, scan, and pair again with the row \
        still showing the old name.
        """
    }

    // MARK: - Finding the device again

    /// Whether a scanned peripheral's name says it is a device this app should connect to.
    ///
    /// This is load-bearing in a way a name match usually is not. Reconnecting to the paired device
    /// is a **scan**, not a lookup of the stored peripheral uuid, and this hardware does not
    /// reliably advertise its service UUID, so the name is in practice the only thing that finds
    /// the cube. A name that matches nothing means every scan times out, on every launch, with no
    /// route back except Forget Device and a broad rescan.
    ///
    /// Two matches, deliberately different shapes:
    ///
    /// - The vendor default is a **substring** test. The hardware ships as "TimeFlip v2.0" and the
    ///   names around it all contain the word, so an exact test would miss most of the family.
    /// - A remembered name is matched **exactly**. It is a specific string this app wrote to a
    ///   specific cube, so there is nothing to be liberal about, and a short user-chosen name like
    ///   "Cube" used as a substring would start claiming other people's hardware.
    /// Whether an advertisement is from a device this app should list or connect to, judged on
    /// **both** names it carries.
    ///
    /// They are genuinely different values on this hardware, and each is the only usable one in
    /// cases the other fails:
    ///
    /// - `peripheralName` is `CBPeripheral.name`, the GAP Device Name, which a rename changes but
    ///   which macOS caches and refreshes only on the next connection. Straight after a rename it
    ///   still reports the previous name, so it can match neither "timeflip" nor the new remembered
    ///   name and the device vanishes from a filtered scan.
    /// - `advertisedName` is the advertisement's local name, which this cube never changes: it
    ///   still reads `TimeFlip v2.0` on a device renamed to something else entirely. That makes it
    ///   the one value that always finds the hardware, at the cost of never showing the user's name.
    ///
    /// Checking one and not the other is exactly the bug this replaced: the connect path checked
    /// both while the discovery scan checked only the peripheral name, so a renamed cube connected
    /// fine but could not be found by a scan (reported 2026-08-01).
    static func matchesKnownDevice(
        peripheralName: String?,
        advertisedName: String?,
        remembered: String?
    ) -> Bool {
        matchesKnownDevice(peripheralName: peripheralName, remembered: remembered)
            || matchesKnownDevice(peripheralName: advertisedName, remembered: remembered)
    }

    static func matchesKnownDevice(peripheralName: String?, remembered: String?) -> Bool {
        let name = (peripheralName ?? "").lowercased()
        guard !name.isEmpty else { return false }
        if name.contains("timeflip") { return true }
        guard let remembered = remembered?.lowercased(), !remembered.isEmpty else { return false }
        return name == remembered
    }

    /// Printable ASCII, `0x20` to `0x7E`.
    ///
    /// The ASCII part is the spec's: the `0x15` entry in `docs/TimeFlip2 BLE Protocol v4.3.md`
    /// reads "name (18 symbols MAX. ASCII coding)", and `setDeviceName` encodes with `.ascii`, so
    /// an accent or an emoji fails to encode at all rather than arriving mangled.
    ///
    /// Excluding the control characters is **this app's** addition, not the spec's -- the spec
    /// says ASCII and stops there. A name is a label in a Bluetooth scan list, and a tab or a NUL
    /// in one is a rendering problem in every app that lists it, for no use anybody has.
    private static func isWritable(_ character: Character) -> Bool {
        guard let ascii = character.asciiValue else { return false }
        return ascii >= 0x20 && ascii <= 0x7E
    }
}

/// What a submitted device name should do. There is no collision case, unlike a category rename:
/// there is only ever one device, and the cube accepts any name that fits.
enum DeviceRenameDecision: Equatable {
    /// Nothing to write: the name is empty once tidied, or already what the device is called.
    case ignore
    case write(String)
    /// The name cannot go to the device as typed, and truncating it to fit would be inventing one.
    case refuse(DeviceNameProblem)
}

enum DeviceNameProblem: Equatable, Identifiable {
    case tooLong(count: Int)
    case unwritableCharacters
    /// The name was acceptable but the device did not take it -- out of range mid-edit, or the
    /// session dropped between opening the field and pressing Return.
    case writeFailed

    var id: String {
        switch self {
        case .tooLong(let count): return "tooLong:\(count)"
        case .unwritableCharacters: return "unwritable"
        case .writeFailed: return "writeFailed"
        }
    }

    /// Named so the two refusals point at the hardware and the write failure does not -- one is
    /// "the cube cannot hold this", the other is "the cube did not answer", and a user told the
    /// wrong one of those will go looking in the wrong place.
    var title: String {
        switch self {
        case .tooLong, .unwritableCharacters: return "The TimeFlip can't store that name"
        case .writeFailed: return "The device didn't accept the new name"
        }
    }

    /// Both refusals name the limit **and** say whose it is.
    ///
    /// The attribution is not decoration. A limit with no owner reads as the app being fussy, and
    /// the user is left thinking a different app would let them use an emoji. These limits come
    /// from the TimeFlip firmware: the vendor's own protocol spec defines the name field as
    /// "18 symbols MAX. ASCII coding", and a name outside that cannot be sent to the device at all.
    /// Saying so is accurate, and it points anyone unhappy about it at the people who can change it.
    var message: String {
        switch self {
        case .tooLong(let count):
            return """
            The TimeFlip has room for only \(DeviceNameRules.maximumLength) characters in its \
            name, and that one is \(count).

            \(Self.notOurRule)

            \(Self.allowance)
            """
        case .unwritableCharacters:
            return """
            The TimeFlip can only store plain, unaccented text in its name, so emoji, accented \
            letters and other symbols cannot be sent to it at all.

            \(Self.notOurRule)

            \(Self.allowance)
            """
        case .writeFailed:
            return """
            The device did not accept the new name. It is still called what it was called \
            before -- check it is connected and try again.
            """
        }
    }

    private static let notOurRule = """
    This is a limit built into the device by TimeFlip, not something this app has decided.
    """

    /// What *will* work, stated in the user's terms rather than the protocol's. Being told a name
    /// is wrong without being told what would be right leaves the user guessing at a rule they
    /// cannot see, which for a field this short means guessing repeatedly.
    private static let allowance = """
    Names can be up to \(DeviceNameRules.maximumLength) characters long, using letters, numbers, \
    spaces and ordinary punctuation.
    """
}
