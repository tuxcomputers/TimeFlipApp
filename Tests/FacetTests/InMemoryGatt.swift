@testable import FacetCore
import Foundation

/// A `CubeGatt` that records what was asked of it and answers whatever a test decides.
///
/// **The second adapter, and the first thing that could ever drive `DeviceLogin`.** That file has never had a
/// test: it held a `CBPeripheral`, so exercising it needed a real radio and a real cube, and everything it
/// decides was covered only by `Tests/Scripted/50`-`66` and by whoever was watching. `DeviceLoginRules` is
/// tested and always was, but the rules are the easy half.
///
/// **It answers in the spelling a real adapter answers in**, which is `TimeFlipUUIDs.canonical`: lowercase, and
/// with the vendor's 16-bit shorthand expanded. That is not a detail. A double that echoed back whatever
/// spelling it was handed would agree with a caller comparing raw strings, and a real cube would not.
@MainActor
final class InMemoryGatt: CubeGatt {
    weak var events: CubeGattEvents?

    struct Write: Equatable {
        let payload: Data
        let characteristic: String
        let acknowledged: Bool
    }

    private(set) var servicesAsked: [[String]] = []
    private(set) var characteristicsAsked: [(uuids: [String]?, service: String)] = []
    private(set) var reads: [String] = []
    private(set) var subscriptions: [String] = []
    private(set) var writes: [Write] = []

    func discoverServices(_ uuids: [String]) {
        servicesAsked.append(uuids)
    }

    func discoverCharacteristics(_ uuids: [String]?, ofService service: String) {
        characteristicsAsked.append((uuids, service))
    }

    func read(_ characteristic: String) {
        reads.append(TimeFlipUUIDs.canonical(characteristic))
    }

    func subscribe(to characteristic: String) {
        subscriptions.append(TimeFlipUUIDs.canonical(characteristic))
    }

    func write(_ payload: Data, to characteristic: String, expectingAcknowledgement: Bool) {
        writes.append(
            Write(
                payload: payload,
                characteristic: TimeFlipUUIDs.canonical(characteristic),
                acknowledged: expectingAcknowledgement
            )
        )
    }

    // MARK: - what a test makes the cube say

    /// Answers a service discovery, in the canonical spelling a real adapter uses.
    func answerServices(_ uuids: [String], failed: String? = nil) {
        events?.servicesDiscovered(uuids.map(TimeFlipUUIDs.canonical), failed: failed)
    }

    /// Answers a characteristic discovery. `notifying` names the ones that declare they can push.
    func answerCharacteristics(
        _ uuids: [String],
        ofService service: String,
        notifying: [String] = [],
        failed: String? = nil
    ) {
        let canNotify = Set(notifying.map(TimeFlipUUIDs.canonical))
        events?.characteristicsDiscovered(
            uuids.map {
                DiscoveredCharacteristic(uuid: $0, canNotify: canNotify.contains(TimeFlipUUIDs.canonical($0)))
            },
            ofService: TimeFlipUUIDs.canonical(service),
            failed: failed
        )
    }

    func acknowledge(_ characteristic: String, failed: String? = nil) {
        events?.writeAcknowledged(to: TimeFlipUUIDs.canonical(characteristic), failed: failed)
    }

    func deliver(_ value: Data?, from characteristic: String, failed: String? = nil) {
        events?.valueArrived(value, from: TimeFlipUUIDs.canonical(characteristic), failed: failed)
    }
}
