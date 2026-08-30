import Foundation

/// What the Device tab's Name row decides when somebody types a new name into it, with none of the AppKit it decides
/// them in -- the seam `CategoryRenameRules` is for the Categories tab.
///
/// **Worth separating here for a reason particular to this field: the limits are the device's, not the app's.** The
/// vendor spec defines the name field as "18 symbols MAX. ASCII coding" (`0x15`, Tab. 1 of
/// `docs/TimeFlip2 BLE Protocol v4.3.md`), so a name outside that cannot reach the cube at all -- and a command that
/// never leaves is a name that silently did not change. Deciding what is acceptable in a pure function is what lets
/// the field refuse the same things up front, and lets those limits be tested with no radio in the room.
///
/// **Massaged from the archive's `DeviceNameRules`.** The decisions are the same and survive inspection; what does not
/// come with them is `matchesKnownDevice`, which arrived in the rebuild earlier as `DeviceScanRules` and belongs with
/// the other question about the two names a cube carries.
enum DeviceNameRules {
    /// The device's own ceiling, not a display choice.
    ///
    /// **The read-back is wider than the write**: `0x2A00` is a 20-byte characteristic, while `0x15` carries a single
    /// length byte and caps the name at 18. So a name arriving from elsewhere can be longer than anything this app is
    /// able to set, which is why nothing truncates what a cube reports.
    static let maximumLength = 18

    /// Why the name will not open for editing, or `nil` when it will.
    ///
    /// **Renaming needs the cube, and that is what separates this row from Forget Device beside it.** The name lives
    /// on the cube; `0x15` is a command that has to arrive somewhere. With nothing on the other end the app could
    /// only write down a name the hardware has never heard, and `device_name` is what the scan filter matches on --
    /// so a name the device never took would be a name nothing could be found by.
    ///
    /// **`nameUnknown` is a real state rather than a defensive one.** The name is read off the peripheral and never
    /// guessed, so a cube that has not told this Mac what it is called leaves the row reading `Unknown`
    /// (`DeviceInfoRules.name`). Opening a field on that placeholder would offer `Unknown` as the name to keep, and a
    /// Return pressed over it would name a cube after the app's own way of saying it did not know.
    static func renameRefusal(isCubePaired: Bool, isCubeConnected: Bool, deviceName: String?) -> RenameRefusal? {
        guard isCubePaired else { return .notPaired }
        guard isCubeConnected else { return .notConnected }
        guard let deviceName, !deviceName.trimmingCharacters(in: .whitespaces).isEmpty else { return .nameUnknown }
        return nil
    }

    /// What a submitted name should do.
    ///
    /// Surrounding whitespace goes: it is invisible on the Device tab and in a scan list, so a name differing from the
    /// current one only by a trailing space would spend a BLE write to produce no visible change. Interior spaces are
    /// kept, `Solid cube` being a reasonable name.
    ///
    /// **The character check is the one the user actually meets.** An emoji or an accent reaches this point, because
    /// the field does not strip it as it is typed: a character that vanished on the keystroke reads as a broken
    /// keyboard, with nothing to say why. It is left visible and refused here, with an alert that names the reason.
    ///
    /// **The length is checked rather than truncated, even though the field has already held it to 18.** From the
    /// field this is unreachable, which is the point: it stands between the cube and a paste that outruns the
    /// truncation, or any later caller that does not come through this field at all. Quietly writing the first 18
    /// characters would name the device something nobody asked for.
    static func renameDecision(typed: String, current: String?) -> DeviceRenameDecision {
        let name = typed.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, name != current?.trimmingCharacters(in: .whitespaces) else { return .ignore }
        guard name.allSatisfy(isWritable) else { return .refuse(.unwritableCharacters) }
        guard name.count <= maximumLength else { return .refuse(.tooLong(count: name.count)) }
        return .write(name)
    }

    /// What to say once a rename has gone out, and why anything is said at all.
    ///
    /// **The rename works, and for a while nothing looks like it did**, in two separate ways, both measured rather
    /// than reasoned about (findings 1 and 2, `docs/timeflip2-firmware-observations.md`):
    ///
    /// - The name in the cube's advertisements never changes. A Bluetooth scan, in this app or any other, goes on
    ///   listing it as `TimeFlip v2.0` permanently.
    /// - The GAP name it reports once connected (`0x2A00`, what `CBPeripheral.name` reads) is re-read by macOS only
    ///   when it next connects, so the old name can survive a reconnect. Polled 120 times over 30 seconds inside the
    ///   connection that renamed it, it never moved.
    ///
    /// Without saying this, somebody renames the cube, goes looking for the new name in a Bluetooth menu, finds the
    /// old one and reasonably concludes the rename failed and that this app broke it. So the notice leads with the
    /// rename having worked, and attributes the lag -- for the same reason `DeviceNameProblem` attributes its limits
    /// rather than merely stating them.
    ///
    /// **It does not promise a way to hurry it along**, and an earlier draft did: the archive told people to Forget
    /// the device, scan and pair again, because that was how *its own* Device tab caught up. This app keeps the name
    /// it wrote (`DevicePairingRules.adoption`), so that sequence would cost a re-pair to change nothing. What lags
    /// is everything outside this app, and nothing here can reach it.
    ///
    /// The attribution is worded to match what is actually established. The unchanging advertised name is squarely
    /// the device's. The stale reported name is the device offering no way to announce a name change, plus macOS
    /// caching what it last read, and those two cannot be separated from a Mac -- so it is described as something the
    /// app cannot change rather than pinned on the firmware alone.
    static func renameLagNotice(newName: String, previousName: String?) -> String {
        let stillReported = previousName.map { "\"\($0)\"" } ?? "the old name"
        return """
        The TimeFlip is now called "\(newName)", and this app will go on calling it that. Elsewhere it will take a \
        while to catch up, and neither half of that is something this app can change: the device goes on advertising \
        its original TimeFlip name in a Bluetooth scan permanently, and macOS itself can report \(stillReported) \
        until the next time it connects to it.
        """
    }

    /// Printable ASCII, `0x20` to `0x7E`.
    ///
    /// The ASCII part is the spec's: the `0x15` entry reads "name (18 symbols MAX. ASCII coding)", and the name is
    /// encoded as ASCII, so an accent or an emoji fails to encode at all rather than arriving mangled.
    ///
    /// Excluding the control characters is **this app's** addition, not the spec's, which says ASCII and stops there.
    /// A name is a label in a scan list, and a tab or a NUL in one is a rendering problem in every app that lists it,
    /// for no use anybody has.
    private static func isWritable(_ character: Character) -> Bool {
        guard let ascii = character.asciiValue else { return false }
        return ascii >= 0x20 && ascii <= 0x7E
    }

    /// Why a name cannot be edited where it stands. The words are the pane's, the decision is here.
    enum RenameRefusal: Equatable {
        case notPaired
        case notConnected
        /// Paired and connected, but the cube has not said what it is called.
        case nameUnknown
    }
}

/// What a submitted device name should do. There is no collision case, unlike a category rename: there is only ever
/// one device, and the cube accepts any name that fits.
enum DeviceRenameDecision: Equatable {
    /// Nothing to write: the name is empty once tidied, or already what the device is called.
    case ignore
    case write(String)
    /// The name cannot go to the device as typed, and truncating it to fit would be inventing one.
    case refuse(DeviceNameProblem)
}

/// What to tell somebody whose name did not take, in the words they meet it in.
enum DeviceNameProblem: Equatable {
    case tooLong(count: Int)
    case unwritableCharacters
    /// The name was acceptable and the cube did not take the command -- out of range mid-edit, or the session dropped
    /// between the field opening and Return.
    case writeFailed

    /// Named so the two refusals point at the hardware and the write failure does not: one is "the cube cannot hold
    /// this", the other is "the cube did not answer", and somebody told the wrong one of those goes looking in the
    /// wrong place.
    var title: String {
        switch self {
        case .tooLong, .unwritableCharacters: return "The TimeFlip cannot store that name"
        case .writeFailed: return "The TimeFlip did not take the new name"
        }
    }

    /// Both refusals name the limit **and** say whose it is.
    ///
    /// The attribution is not decoration. A limit with no owner reads as the app being fussy, and leaves somebody
    /// thinking a different app would allow an emoji. These limits are the TimeFlip firmware's: the vendor's own
    /// protocol defines the name field as "18 symbols MAX. ASCII coding", and a name outside that cannot be sent to
    /// the device at all. Saying so is accurate, and it points anybody unhappy about it at the people who can change
    /// it.
    var message: String {
        switch self {
        case .tooLong(let count):
            return """
            The TimeFlip has room for only \(DeviceNameRules.maximumLength) characters in its name, and that one is \
            \(count).

            \(Self.notOurRule)

            \(Self.allowance)
            """
        case .unwritableCharacters:
            return """
            The TimeFlip can only store plain, unaccented text in its name, so emoji, accented letters and other \
            symbols cannot be sent to it at all.

            \(Self.notOurRule)

            \(Self.allowance)
            """
        case .writeFailed:
            // **Nothing about the character rules here, deliberately.** A cube that did not answer is a different
            // problem from a name it cannot hold, and quoting the limits at a connection fault sends somebody
            // looking in the wrong place.
            //
            // **And nothing claiming the cube refused it either.** `0x15` has no reply of its own (finding 2,
            // `docs/timeflip2-firmware-observations.md`), so what failed here is the write reaching the device, not
            // the device turning the name down.
            return """
            The new name could not be sent to the device, so it is still called what it was called before.

            Check that it is connected and try again.
            """
        }
    }

    private static let notOurRule = """
    This is a limit built into the device by TimeFlip, not something this app has decided.
    """

    /// What *will* work, in the user's terms rather than the protocol's. Being told a name is wrong without being
    /// told what would be right leaves somebody guessing at a rule they cannot see, which for a field this short
    /// means guessing repeatedly.
    private static let allowance = """
    Names can be up to \(DeviceNameRules.maximumLength) characters long, using letters, numbers, spaces and \
    ordinary punctuation.
    """
}
