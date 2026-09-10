#if canImport(CDBus)
import FacetCore
import Foundation

/// Reading, writing and listening to a connected cube's characteristics.
///
/// **The three calls plus one signal that the whole protocol is made of.** `ReadValue` and `WriteValue`
/// carry `ay`, and `StartNotify` turns a characteristic into a stream of `PropertiesChanged` signals whose
/// `Value` is the same `ay` -- so every one of the vendor's commands, answers and face turns is one of
/// these four things with different bytes in it.
package final class BlueZGatt {
    package enum Failure: Error, Equatable {
        /// No characteristic with that UUID on this device. **The likeliest cause is not the cube**: a
        /// UUID compared in the wrong spelling finds nothing, which is what `TimeFlipUUIDs.canonical` is
        /// for, and services that are not resolved yet look identical to a cube that has none.
        case noSuchCharacteristic(uuid: String)
        case refused(String)
    }

    private let bus: SystemBus
    private let characteristicInterface = BlueZObjectTree.characteristicInterface

    package init(bus: SystemBus) {
        self.bus = bus
    }

    // MARK: - reading and writing

    /// Reads a characteristic's value.
    ///
    /// The options dictionary is empty and required: `ReadValue` takes `a{sv}` and BlueZ refuses the call
    /// without it, which is a signature error rather than anything about the cube.
    package func read(path: String) throws -> [UInt8] {
        do {
            let reply = try bus.call(
                destination: "org.bluez", path: path,
                interface: characteristicInterface, method: "ReadValue",
                arguments: [.dictionary([:])]
            )
            return reply.first?.data ?? []
        } catch let failure as SystemBus.Failure {
            throw Failure.refused(Self.describe(failure))
        }
    }

    /// Writes bytes to a characteristic.
    ///
    /// **Nothing here decides whether the write worked.** BlueZ answering without error means the bytes
    /// reached the device at the ATT layer, which is one of the two acknowledgements `CLAUDE.md` warns are
    /// less than they look: a cube refuses every command until a PIN has been accepted, and refuses it
    /// *after* the write has already succeeded. What says a command took effect is the read-back.
    package func write(path: String, bytes: [UInt8]) throws {
        do {
            try bus.call(
                destination: "org.bluez", path: path,
                interface: characteristicInterface, method: "WriteValue",
                arguments: [.bytes(bytes), .dictionary([:])]
            )
        } catch let failure as SystemBus.Failure {
            throw Failure.refused(Self.describe(failure))
        }
    }

    // MARK: - listening

    /// Subscribes to a characteristic, so its values start arriving as signals.
    ///
    /// **The match rule comes first.** A subscription that starts before the process is listening can push
    /// a value into a bus nobody is reading, and on this platform the value is only ever delivered as a
    /// signal -- there is no second way to ask for the one that was missed.
    package func startNotifying(path: String) throws {
        try bus.addMatch(
            "type='signal',sender='org.bluez',interface='org.freedesktop.DBus.Properties'"
                + ",member='PropertiesChanged',path='\(path)'"
        )
        do {
            try bus.call(
                destination: "org.bluez", path: path,
                interface: characteristicInterface, method: "StartNotify"
            )
        } catch let failure as SystemBus.Failure {
            // Already notifying is the state asked for.
            guard case let .callFailed(name, _) = failure, name.hasSuffix(".InProgress") else {
                throw Failure.refused(Self.describe(failure))
            }
        }
    }

    package func stopNotifying(path: String) throws {
        do {
            try bus.call(
                destination: "org.bluez", path: path,
                interface: characteristicInterface, method: "StopNotify"
            )
        } catch let failure as SystemBus.Failure {
            throw Failure.refused(Self.describe(failure))
        }
    }

    /// The next value pushed by a characteristic, or `nil` if none arrived in the wait.
    ///
    /// **Filtered by what was asked for rather than by what arrives.** The bus sends a new connection its
    /// own `NameAcquired` whatever it subscribed to, and a `PropertiesChanged` on a characteristic can
    /// carry `Notifying` rather than `Value` -- so a signal is only a value if it says so.
    package func nextValue(waitingMilliseconds: Int32 = 250) -> (path: String, bytes: [UInt8])? {
        guard let signal = bus.nextSignal(waitingMilliseconds: waitingMilliseconds) else { return nil }
        guard signal.member == "PropertiesChanged",
              signal.arguments.first?.text == characteristicInterface,
              let changed = signal.arguments.dropFirst().first?.members,
              let bytes = changed["Value"]?.data
        else { return nil }
        return (signal.path, bytes)
    }

    private static func describe(_ failure: SystemBus.Failure) -> String {
        switch failure {
        case let .callFailed(name, message): return "\(name): \(message)"
        case let .noBus(message), let .unexpectedReply(message), let .matchFailed(message): return message
        }
    }
}
#endif
