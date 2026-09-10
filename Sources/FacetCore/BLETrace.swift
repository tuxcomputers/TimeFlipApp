import Foundation

/// Every byte this app sends the cube and every byte it gets back, as a `debug_log` row.
///
/// **The whole conversation, not the parts a feature happened to find interesting.** This is the one kind of logging
/// worth doing unconditionally, and the archive is the argument for it: `docs/timeflip2-firmware-observations.md`
/// exists because a complete `ble-tx`/`ble-rx` trace was there to read afterwards, and all three of its findings are
/// things nobody set out to measure. Finding 2 in particular -- that most commands never update the command result
/// characteristic, so a stale answer from a previous command reads as success -- could only be seen by having every
/// write and every value side by side in one ordered list.
///
/// Two tags rather than one, because direction is the first thing anybody reading a trace needs and grepping for an
/// arrow inside a message is not the same as being able to ask the table for one side of the conversation.
///
/// **`ble-tx` is anything the host sends, bytes or not**, which is the archive's meaning and is why a read request
/// and a discovery are `ble-tx` rows despite carrying no payload: they are packets going out, and each is a round
/// trip that can fail. What is *not* kept from the archive is its wording -- it wrote `read request batteryLevel` and
/// `batteryLevel -> 63`, leading with the operation and marking direction with an arrow inside the message. Every row
/// here leads with the characteristic instead, so one `LIKE 'batteryLevel%'` gets a characteristic's whole
/// conversation in both directions, and the arrows are gone because the tag already carries what they said.
///
/// **Bytes as they went, including the PIN.** The login write is six ASCII digits and they appear here in hex like
/// everything else: a trace with a hole in it is worth less than no trace, and this log only exists in a developer
/// build (`DebugLog` is `nil` otherwise). Anything printable is rendered beside the hex, which is what turns the
/// cube's undocumented ASCII narration (finding 3) from a row of numbers into a sentence.
///
/// **In `FacetCore` since 2026-09-11, keyed on UUID strings**, and that is the two-copies rule rather than tidying.
/// It sat in `FacetMac` keyed on `CBUUID` while CoreBluetooth was the only radio; BlueZ is a second one and would
/// have had to write these rows too. Every wording in here is read back by `Tests/Scripted` with SQL `LIKE` and
/// `GLOB` patterns, so a second copy would be two platforms whose traces diverge one row at a time with nothing to
/// notice. `Sources/FacetMac/BLETrace.swift` is now the `CBUUID` spellings of these and no wording of its own.
extension DebugLog {
    /// A write on its way out.
    package func transmitted(_ data: Data, to uuid: String, acknowledged: Bool) {
        let kind = acknowledged ? "withResponse" : "withoutResponse"
        record(.transmit, "\(BLETrace.name(for: uuid)) \(kind): \(BLETrace.describe(data))")
    }

    /// A value arriving: the answer to a read, or a notification the cube sent unasked. Both are the same row,
    /// deliberately, because the characteristic and the bytes are what matter and both platforms deliver them
    /// through one callback either way.
    package func received(_ data: Data?, from uuid: String, failed: String?) {
        let name = BLETrace.name(for: uuid)
        if let failed {
            record(.receive, "\(name): failed, \(failed)")
            return
        }
        guard let data else {
            record(.receive, "\(name): no value")
            return
        }
        record(.receive, "\(name): \(BLETrace.describe(data))")
    }

    /// A write the cube acknowledged, or refused. Not bytes, but it is the other half of an acknowledged write and
    /// belongs in the same ordered list: a write that was never acknowledged looks identical to one that was, unless
    /// the acknowledgement is a row too.
    package func acknowledged(_ uuid: String, failed: String?) {
        let name = BLETrace.name(for: uuid)
        record(.receive, failed.map { "\(name): write refused, \($0)" } ?? "\(name): write acknowledged")
    }

    /// A read on its way out.
    ///
    /// **Carries no bytes and is the row the trace most needs.** Without it a value in the log cannot be told from a
    /// value the cube volunteered, and that distinction is the whole of finding 7 in
    /// `docs/timeflip2-firmware-observations.md` -- which could only be measured because the archive logged its reads.
    package func requested(_ uuid: String) {
        record(.transmit, "\(BLETrace.name(for: uuid)): read requested")
    }

    /// A subscription being turned on or off.
    package func subscribing(_ enabled: Bool, to uuid: String) {
        record(.transmit, "\(BLETrace.name(for: uuid)): notify \(enabled ? "on" : "off") requested")
    }

    /// What the cube made of it. **A refused subscription and a characteristic that never changes are both silence**,
    /// so without this row there is no way to tell a feature that stopped hearing from one that has nothing to hear.
    package func notifying(_ uuid: String, isNotifying: Bool, failed: String?) {
        let name = BLETrace.name(for: uuid)
        record(
            .receive,
            failed.map { "\(name): notify refused, \($0)" }
                ?? "\(name): \(isNotifying ? "notifying" : "not notifying")"
        )
    }

    /// A discovery on its way out. Discovery is traffic like any other -- round trips that can fail, and that a cube
    /// missing a service answers differently -- so it is in the list rather than only in whichever feature asked.
    package func discovering(services uuids: [String]) {
        record(.transmit, "discover services: \(BLETrace.names(uuids))")
    }

    package func discovering(characteristics uuids: [String]?, of service: String) {
        let asked = uuids.map { BLETrace.names($0) } ?? "everything"
        record(.transmit, "discover characteristics on \(BLETrace.name(for: service)): \(asked)")
    }

    /// What came back. **The whole list every time**, because that is what CoreBluetooth hands over: `peripheral
    /// .services` accumulates across discoveries, so the third one answers with all three and a row naming only what
    /// was asked for would be this app's summary rather than the cube's answer. BlueZ answers with the whole tree for
    /// the same reason from the other direction: it never had a per-request answer to give.
    package func discovered(services uuids: [String], failed: String?) {
        record(.receive, failed.map { "service discovery failed, \($0)" } ?? "services: \(BLETrace.names(uuids))")
    }

    /// **The inventory, and the archive's reason for it kept verbatim**: this names every characteristic the cube
    /// actually exposes, including ones nothing here touches, so the log says what traffic is even *possible* beside
    /// the traffic that happened. A UUID appearing here unnamed is one to go and look up in the spec.
    package func discovered(characteristics uuids: [String], of service: String, failed: String?) {
        let name = BLETrace.name(for: service)
        record(.receive, failed.map { "\(name): characteristic discovery failed, \($0)" }
            ?? "\(name): characteristics \(BLETrace.names(uuids))")
    }
}

/// How bytes are written down. Its own type so the format is one decision rather than one per call site.
package enum BLETrace {
    /// A readable name for the raw comms log.
    ///
    /// **Falls back to the bare UUID rather than to "unknown"**, which is the archive's decision and worth keeping
    /// verbatim: the point of logging every characteristic is to see traffic this app has no handler for, so a UUID
    /// appearing here unnamed is a genuine finding and has to be printed in full to be looked up in the spec.
    package static func name(for uuid: String) -> String {
        TimeFlipUUIDs.name(for: uuid) ?? uuid
    }

    /// A list of characteristics or services, named. `none` rather than an empty string, so a discovery that came
    /// back with nothing is a row that says so rather than one that looks truncated.
    package static func names(_ uuids: [String]) -> String {
        uuids.isEmpty ? "none" : uuids.map { name(for: $0) }.joined(separator: ", ")
    }

    /// `30 30 30 30 30 30 (000000)`, with the bracketed half present only when the bytes are readable.
    ///
    /// **Hex first and always.** The text is a convenience for the ASCII the cube narrates with; the hex is the
    /// record, and a rendering that replaced it would lose exactly the bytes a surprise is made of.
    ///
    /// **Brackets rather than quotation marks**, which is not decoration: the two halves need separating or the ASCII
    /// runs straight on from the hex, and every debug message is plain text now -- no apostrophes, no quotation marks
    /// -- because they are read back out with SQL `LIKE` patterns and both need escaping on the way (see `CLAUDE.md`).
    /// Brackets need escaping nowhere and the app already writes `(category_id 4)` in the same breath.
    ///
    /// The bytes are rendered as text only when every one of them is printable ASCII. All of them, not most: a frame
    /// that is half readable is a binary frame that happens to contain letters, and rendering it as a string invites
    /// reading meaning into a coincidence.
    package static func describe(_ data: Data) -> String { CubeBytes.describe(data) }
}
