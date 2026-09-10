import Foundation
import Testing
@testable import FacetCore

/// `TimeFlipUUIDs.canonical` and `match`: the one thing the two platforms disagree about.
///
/// **The expected strings here are not derived from the code under test.** The 128-bit forms are what BlueZ on a
/// real machine prints for the standard services -- `bluetoothctl show` lists its adapter's UUIDs in exactly this
/// spelling -- and the vendor's own are from `docs/TimeFlip2 BLE Protocol v4.3.md`. If the expansion were wrong,
/// every characteristic lookup against a `GattCharacteristic1` object would silently find nothing.
@Suite
struct TimeFlipUUIDTests {
    @Test func aSixteenBitShorthandExpandsToWhatBlueZReports() {
        // The Battery Service and its one characteristic, as BlueZ spells them.
        #expect(TimeFlipUUIDs.canonical("180F") == "0000180f-0000-1000-8000-00805f9b34fb")
        #expect(TimeFlipUUIDs.canonical("2A19") == "00002a19-0000-1000-8000-00805f9b34fb")
        // And the Device Information four.
        #expect(TimeFlipUUIDs.canonical("180A") == "0000180a-0000-1000-8000-00805f9b34fb")
        #expect(TimeFlipUUIDs.canonical("2A29") == "00002a29-0000-1000-8000-00805f9b34fb")
    }

    @Test func aVendorUUIDIsOnlyLowercased() {
        // Already 128-bit, so nothing is expanded -- but CoreBluetooth holds these uppercase and BlueZ answers
        // lowercase, which on its own is enough to make a string comparison fail.
        #expect(
            TimeFlipUUIDs.canonical(TimeFlipUUIDs.serviceString)
                == "f1196f50-71a4-11e6-bdf4-0800200c9a66"
        )
        #expect(
            TimeFlipUUIDs.canonical(TimeFlipUUIDs.commandString)
                == "f1196f54-71a4-11e6-bdf4-0800200c9a66"
        )
    }

    @Test func aThirtyTwoBitShorthandExpandsTheSameWay() {
        // Allowed by the specification and used by nothing here, which is the reason to have decided what it does
        // rather than leave it to whichever branch happened to catch it.
        #expect(TimeFlipUUIDs.canonical("0000180F") == "0000180f-0000-1000-8000-00805f9b34fb")
    }

    @Test func matchingIgnoresHowEitherSideIsSpelled() {
        #expect(TimeFlipUUIDs.match("2A19", "00002a19-0000-1000-8000-00805f9b34fb"))
        #expect(TimeFlipUUIDs.match("00002A19-0000-1000-8000-00805F9B34FB", "2a19"))
        #expect(TimeFlipUUIDs.match(TimeFlipUUIDs.facesString, "f1196f52-71a4-11e6-bdf4-0800200c9a66"))
        #expect(!TimeFlipUUIDs.match("2A19", "2A29"), "the battery level is not the manufacturer name")
    }

    @Test func somethingThatIsNotAUUIDIsHandedBackRatherThanGuessedAt() {
        // This decides how to spell a UUID, not whether it is one: a caller comparing rubbish should get a
        // mismatch, not an expansion of the rubbish into something that might collide.
        #expect(TimeFlipUUIDs.canonical("not a uuid") == "not a uuid")
        #expect(TimeFlipUUIDs.canonical("ZZZZ") == "zzzz", "four characters, but not hex")
        #expect(TimeFlipUUIDs.canonical("") == "")
    }

    @Test func theVendorUUIDsAreTheOnesTheProtocolDocumentLists() {
        // A transcription check, since every one of these is a hand-copied hex string and a wrong digit is a
        // characteristic the app would look for and never find.
        #expect(TimeFlipUUIDs.serviceString == "F1196F50-71A4-11E6-BDF4-0800200C9A66")
        #expect(TimeFlipUUIDs.eventsDataString == "F1196F51-71A4-11E6-BDF4-0800200C9A66")
        #expect(TimeFlipUUIDs.facesString == "F1196F52-71A4-11E6-BDF4-0800200C9A66")
        #expect(TimeFlipUUIDs.commandResultString == "F1196F53-71A4-11E6-BDF4-0800200C9A66")
        #expect(TimeFlipUUIDs.commandString == "F1196F54-71A4-11E6-BDF4-0800200C9A66")
        #expect(TimeFlipUUIDs.doubleTapString == "F1196F55-71A4-11E6-BDF4-0800200C9A66")
        #expect(TimeFlipUUIDs.systemStateString == "F1196F56-71A4-11E6-BDF4-0800200C9A66")
        #expect(TimeFlipUUIDs.passwordString == "F1196F57-71A4-11E6-BDF4-0800200C9A66")
        #expect(TimeFlipUUIDs.historyString == "F1196F58-71A4-11E6-BDF4-0800200C9A66")
    }

    /// The names are interface, and there is one table of them.
    ///
    /// **These exact spellings are read back out of `debug_log`.** `Tests/Scripted` matches the trace with SQL
    /// `LIKE` and `GLOB` patterns naming them -- `commandResult: 02`, `batteryLevel: [0-9A-F]`,
    /// `timeFlipService: characteristics%`, `Found characteristic commandResult%` -- and that suite is set aside,
    /// so a tidied name would break checks that cannot say so.
    ///
    /// **Written down because there used to be two tables and they disagreed.** The Mac target had its own switch
    /// keyed on `CBUUID` spelling these in camelCase, and the core had this one spelling them with spaces. Nothing
    /// called the core's, so the two never met -- until `DeviceLogin` moved into the core on 2026-09-10 and started
    /// resolving to it, which silently changed two of its log rows and failed `51-device-connect`.
    @Test func everyNamedUUIDKeepsTheSpellingTheTraceIsReadBackBy() {
        let expected = [
            "timeFlipService", "commandResult", "command", "password", "eventsData", "faces", "doubleTap",
            "systemState", "history", "deviceInformation", "manufacturerName", "modelNumber", "hardwareRevision",
            "firmwareRevision", "batteryService", "batteryLevel",
        ]
        #expect(TimeFlipUUIDs.named.map(\.1) == expected)
    }

    @Test func aNameIsFoundWhicheverWayTheUUIDIsSpelled() {
        // The whole reason the lookup goes through `match`: CoreBluetooth hands over `2A19` and the vendor's own
        // uppercase, BlueZ hands over the expanded lowercase, and both have to find the same row.
        #expect(TimeFlipUUIDs.name(for: "2A19") == "batteryLevel")
        #expect(TimeFlipUUIDs.name(for: "00002a19-0000-1000-8000-00805f9b34fb") == "batteryLevel")
        #expect(TimeFlipUUIDs.name(for: TimeFlipUUIDs.commandResultString) == "commandResult")
        #expect(
            TimeFlipUUIDs.name(for: TimeFlipUUIDs.commandResultString.lowercased()) == "commandResult",
            "which is the spelling a real adapter answers in"
        )
    }

    @Test func aUUIDTheAppHasNeverNamedHasNoName() {
        // `nil` rather than a placeholder, so each caller falls back to the bare UUID: a characteristic appearing
        // in the trace unnamed is a finding, and it has to be printed in full to be looked up in the spec.
        #expect(TimeFlipUUIDs.name(for: "F1196FFF-71A4-11E6-BDF4-0800200C9A66") == nil)
    }
}
