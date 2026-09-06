import Foundation

/// One advertisement, reduced to the four things a decision about it can be made from.
///
/// **A value rather than a `CBPeripheral`**, which is what makes every rule below testable with no radio: a
/// `CBPeripheral` cannot be constructed outside CoreBluetooth, so a scanner that decided things about one directly
/// could only ever be tested by holding a cube. `BluetoothScanner` turns each callback into one of these and asks
/// the rules; the rules are the part with the reasoning in it.
struct ScannedDevice: Equatable, Identifiable {
    /// The peripheral identifier CoreBluetooth assigns. **This Mac's name for the device, not the device's own**:
    /// it is stable on this machine and meaningless on any other, which is why `device_uuid` is described the way
    /// it is in `database/011_setting.sql`.
    let id: UUID

    /// `CBPeripheral.name`, the GAP Device Name. What a rename changes, and what macOS caches.
    let peripheralName: String?

    /// The advertisement's local name. **This cube never changes it**, so it still reads `TimeFlip v2.0` on a device
    /// renamed to something else entirely.
    let advertisedName: String?

    /// Whether the advertisement carried the TimeFlip service UUID. Rarely true on real hardware, hence the names.
    let advertisesTimeFlipService: Bool
}

/// Which advertisements the Device tab lists, and what it calls them.
///
/// **The names are the whole problem, and they are the archive's hardest-won measurement.** A TimeFlip carries two
/// different names at once and a rename moves only one of them (`docs/timeflip2-firmware-observations.md`, finding 1,
/// confirmed across seven renames):
///
/// - The **advertised** local name never changes. It stays `TimeFlip v2.0` for the life of the device.
/// - The **GAP** name is what `0x15` writes and what `CBPeripheral.name` reports, and macOS re-reads it only on the
///   next connection, so straight after a rename it is still the previous name.
///
/// So matching on one name alone fails, in opposite directions: only the GAP name loses a renamed cube from the scan
/// entirely, and only the advertised name finds the hardware but can never show the user the name they chose. The
/// archive shipped exactly that bug -- its connect path checked both while its discovery scan checked one -- and a
/// renamed cube connected fine while being undiscoverable (reported 2026-08-01).
///
/// **Massaged from `DeviceNameRules.matchesKnownDevice` rather than copied**: the decisions are the same and are
/// right, but they arrive here as a value with both names on it instead of two overloads taking loose strings, and
/// the label rule moves in beside them, because choosing what to match on and choosing what to display are the same
/// question asked twice about the same pair of names.
enum DeviceScanRules {
    /// The vendor's own name, matched as a substring.
    ///
    /// Substring rather than equality because the hardware ships as `TimeFlip v2.0` and the family's names all
    /// contain the word, so an exact test would miss most of them. A remembered name gets the opposite treatment
    /// below, and for the opposite reason.
    static let vendorName = "timeflip"

    /// Whether this advertisement is one the filtered scan should list.
    ///
    /// - Parameters:
    ///   - remembered: `device_name.name`, the name the cube is currently carrying. Read from the table at the
    ///     moment a scan starts, never held.
    ///   - previouslyKnown: `device_name.previous_name`, the name before that. It is here for the stale GAP read: the
    ///     scan immediately after a rename still sees the old name, which is exactly when somebody is watching for
    ///     the new one.
    static func isEligible(_ device: ScannedDevice, remembered: String?, previouslyKnown: String?) -> Bool {
        if device.advertisesTimeFlipService { return true }
        return [device.peripheralName, device.advertisedName].contains {
            matches($0, remembered: remembered, previouslyKnown: previouslyKnown)
        }
    }

    private static func matches(_ name: String?, remembered: String?, previouslyKnown: String?) -> Bool {
        let name = (name ?? "").lowercased()
        guard !name.isEmpty else { return false }
        if name.contains(vendorName) { return true }
        // **Exact**, unlike the vendor test. A remembered name is one specific string this app wrote to one specific
        // cube, so there is nothing to be liberal about, and a short chosen name like "Cube" used as a substring
        // would start claiming other people's hardware.
        return [remembered, previouslyKnown]
            .compactMap { $0?.lowercased() }
            .contains { !$0.isEmpty && $0 == name }
    }

    /// What to call it in the list.
    ///
    /// **`CBPeripheral.name` first, the advertised name only as a fallback.** That looks backwards given the advertised
    /// name is the reliable one, and it is deliberate: the advertised name never changes, so preferring it would list
    /// every renamed cube as `TimeFlip v2.0` and the user would never see the name they chose. The GAP name is a
    /// connection stale rather than wrong, so it is the better label and the worse filter, which is why this rule and
    /// `isEligible` read the same two values in opposite priority.
    ///
    /// A device with neither is still listed, under a placeholder: an advertisement with no name at all is exactly
    /// what somebody scanning with **All Devices** ticked is looking at, and dropping it would make the escape hatch
    /// out of the filter narrower than the filter.
    static func label(for device: ScannedDevice) -> String {
        for name in [device.peripheralName, device.advertisedName] {
            if let name, !name.trimmingCharacters(in: .whitespaces).isEmpty { return name }
        }
        return "Unnamed device"
    }

    /// The order a reach asks devices in: the remembered identifier, then everything called what the cube is called
    /// now, then what it was called before, then anything else the filter let through.
    ///
    /// **Ordering, never filtering, and every rank exists because the one above it can be wrong.** The identifier
    /// leads because it is the surest thing available when it is right, and it is only a hint: neither identifier
    /// this app can see is unique to a cube (finding 8, `docs/timeflip2-firmware-observations.md`), so a device
    /// carrying it can be somebody else's and a cube that has been re-paired or moved between Macs can be this
    /// app's and not carry it. The name is next for the same reason and with the same limit: a renamed cube is
    /// almost certainly the one that was renamed, and a room of factory-named cubes tells them apart not at all.
    ///
    /// So the order is a ranking of guesses, and **the answer is the PIN** -- which is why the caller works through
    /// the whole list rather than trusting any position in it (`BluetoothRadio.ReachTarget`).
    ///
    /// The previous name is behind the current one rather than beside it: both are this app's own writing, and the
    /// one it wrote last is the one the cube should be answering to.
    static func reachOrder(
        _ devices: [ScannedDevice],
        preferring preferred: UUID?,
        remembered: String?,
        previouslyKnown: String?
    ) -> [UUID] {
        func rank(_ device: ScannedDevice) -> Int {
            if let preferred, device.id == preferred { return 0 }
            if isCalled(device, remembered) { return 1 }
            if isCalled(device, previouslyKnown) { return 2 }
            return 3
        }
        return devices
            .sorted { first, second in
                if rank(first) != rank(second) { return rank(first) < rank(second) }
                // Broken the same way the list is, so a room scanned twice is asked in the same order twice: a
                // dictionary hands its values over in whatever order it likes.
                let comparison = label(for: first).localizedCaseInsensitiveCompare(label(for: second))
                if comparison != .orderedSame { return comparison == .orderedAscending }
                return first.id.uuidString < second.id.uuidString
            }
            .map(\.id)
    }

    /// Whether either name a device offers is exactly this one. **Exact**, matching `matches` above and for its
    /// reason: a remembered name is one string this app wrote to one cube, so a chosen name like "Cube" used as a
    /// substring would start claiming other people's hardware.
    private static func isCalled(_ device: ScannedDevice, _ name: String?) -> Bool {
        guard let name = name?.lowercased(), !name.isEmpty else { return false }
        return [device.peripheralName, device.advertisedName]
            .compactMap { $0?.lowercased() }
            .contains(name)
    }

    /// The order the list is drawn in: anything eligible first, then by name, then by identifier.
    ///
    /// **Ordering, not filtering**, which matters once **All Devices** is ticked: the point of that box is to show a
    /// cube the filter cannot see, and it would be useless if the one device being looked for sat at the bottom of a
    /// room's worth of headphones. Sorted by name rather than by arrival so two scans of the same room produce the
    /// same list, and broken by identifier so two devices sharing a name do not swap places between redraws.
    static func ordered(_ devices: [ScannedDevice], remembered: String?, previouslyKnown: String?) -> [ScannedDevice] {
        devices.sorted { first, second in
            let firstEligible = isEligible(first, remembered: remembered, previouslyKnown: previouslyKnown)
            let secondEligible = isEligible(second, remembered: remembered, previouslyKnown: previouslyKnown)
            if firstEligible != secondEligible { return firstEligible }
            let comparison = label(for: first).localizedCaseInsensitiveCompare(label(for: second))
            if comparison != .orderedSame { return comparison == .orderedAscending }
            return first.id.uuidString < second.id.uuidString
        }
    }
}
