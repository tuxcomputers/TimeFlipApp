import CoreBluetooth
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
extension DebugLog {
    /// A write on its way out.
    func transmitted(_ data: Data, to uuid: CBUUID, type: CBCharacteristicWriteType) {
        let acknowledged = type == .withResponse ? "withResponse" : "withoutResponse"
        record(.transmit, "\(TimeFlipUUIDs.name(for: uuid)) \(acknowledged): \(BLETrace.describe(data))")
    }

    /// A value arriving: the answer to a read, or a notification the cube sent unasked. Both are the same row,
    /// deliberately, because the characteristic and the bytes are what matter and CoreBluetooth delivers them
    /// through one callback either way.
    func received(_ data: Data?, from uuid: CBUUID, error: Error?) {
        let name = TimeFlipUUIDs.name(for: uuid)
        if let error {
            record(.receive, "\(name): failed, \(error.localizedDescription)")
            return
        }
        guard let data else {
            record(.receive, "\(name): no value")
            return
        }
        record(.receive, "\(name): \(BLETrace.describe(data))")
    }

    /// A write the cube acknowledged, or refused. Not bytes, but it is the other half of a `withResponse` write and
    /// belongs in the same ordered list: a write that was never acknowledged looks identical to one that was, unless
    /// the acknowledgement is a row too.
    func acknowledged(_ uuid: CBUUID, error: Error?) {
        let name = TimeFlipUUIDs.name(for: uuid)
        record(.receive, error.map { "\(name): write refused, \($0.localizedDescription)" } ?? "\(name): write acknowledged")
    }

    /// A read on its way out.
    ///
    /// **Carries no bytes and is the row the trace most needs.** Without it a value in the log cannot be told from a
    /// value the cube volunteered, and that distinction is the whole of finding 7 in
    /// `docs/timeflip2-firmware-observations.md` -- which could only be measured because the archive logged its reads.
    func requested(_ uuid: CBUUID) {
        record(.transmit, "\(TimeFlipUUIDs.name(for: uuid)): read requested")
    }

    /// A subscription being turned on or off.
    func subscribing(_ enabled: Bool, to uuid: CBUUID) {
        record(.transmit, "\(TimeFlipUUIDs.name(for: uuid)): notify \(enabled ? "on" : "off") requested")
    }

    /// What the cube made of it. **A refused subscription and a characteristic that never changes are both silence**,
    /// so without this row there is no way to tell a feature that stopped hearing from one that has nothing to hear.
    func notifying(_ uuid: CBUUID, isNotifying: Bool, error: Error?) {
        let name = TimeFlipUUIDs.name(for: uuid)
        record(
            .receive,
            error.map { "\(name): notify refused, \($0.localizedDescription)" }
                ?? "\(name): \(isNotifying ? "notifying" : "not notifying")"
        )
    }

    /// A discovery on its way out. Discovery is traffic like any other -- round trips that can fail, and that a cube
    /// missing a service answers differently -- so it is in the list rather than only in whichever feature asked.
    func discovering(services uuids: [CBUUID]) {
        record(.transmit, "discover services: \(BLETrace.names(uuids))")
    }

    func discovering(characteristics uuids: [CBUUID]?, of service: CBUUID) {
        let asked = uuids.map { BLETrace.names($0) } ?? "everything"
        record(.transmit, "discover characteristics on \(TimeFlipUUIDs.name(for: service)): \(asked)")
    }

    /// What came back. **The whole list every time**, because that is what CoreBluetooth hands over: `peripheral
    /// .services` accumulates across discoveries, so the third one answers with all three and a row naming only what
    /// was asked for would be this app's summary rather than the cube's answer.
    func discovered(services uuids: [CBUUID], error: Error?) {
        record(.receive, error.map { "service discovery failed, \($0.localizedDescription)" }
            ?? "services: \(BLETrace.names(uuids))")
    }

    /// **The inventory, and the archive's reason for it kept verbatim**: this names every characteristic the cube
    /// actually exposes, including ones nothing here touches, so the log says what traffic is even *possible* beside
    /// the traffic that happened. A UUID appearing here unnamed is one to go and look up in the spec.
    func discovered(characteristics uuids: [CBUUID], of service: CBUUID, error: Error?) {
        let name = TimeFlipUUIDs.name(for: service)
        record(.receive, error.map { "\(name): characteristic discovery failed, \($0.localizedDescription)" }
            ?? "\(name): characteristics \(BLETrace.names(uuids))")
    }
}

/// How bytes are written down. Its own type so the format is one decision rather than one per call site.
enum BLETrace {
    /// A list of characteristics or services, named. `none` rather than an empty string, so a discovery that came
    /// back with nothing is a row that says so rather than one that looks truncated.
    static func names(_ uuids: [CBUUID]) -> String {
        uuids.isEmpty ? "none" : uuids.map { TimeFlipUUIDs.name(for: $0) }.joined(separator: ", ")
    }

    /// `30 30 30 30 30 30 "000000"`, with the quoted half present only when the bytes are readable.
    ///
    /// **Hex first and always.** The text is a convenience for the cube's ASCII narration; the hex is the record, and
    /// a rendering that replaced it would lose exactly the bytes a surprise is made of.
    static func describe(_ data: Data) -> String {
        let hex = data.map { String(format: "%02X", $0) }.joined(separator: " ")
        guard let text = printable(data) else { return hex }
        return "\(hex) \"\(text)\""
    }

    /// The bytes as text, when every one of them is printable ASCII. All of them, not most: a frame that is half
    /// readable is a binary frame that happens to contain letters, and rendering it as a string invites reading
    /// meaning into a coincidence.
    private static func printable(_ data: Data) -> String? {
        guard !data.isEmpty, data.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}
