#if canImport(CDBus)
import Foundation
import Testing
@testable import FacetCore

/// `SystemBus` against the real system bus.
///
/// **These talk to the machine rather than to a fixture, and that is the point.** What this type does is
/// marshalling: turning Swift values into D-Bus wire types and a reply back into a tree. A fixture would
/// only prove the code agrees with itself, and the failure mode being guarded against is a reply walked
/// wrongly -- which looks like a characteristic that is not there rather than like an error.
///
/// **`org.freedesktop.DBus` rather than BlueZ, wherever the test can use it.** The bus daemon is on any
/// machine with a system bus and answers the same shapes; BlueZ is only asked about where BlueZ is the
/// subject, and those tests say so if it is absent rather than failing.
@Suite(.timeLimit(.minutes(1)))
struct SystemBusTests {
    @Test func theSystemBusCanBeReached() throws {
        _ = try SystemBus()
    }

    /// `ListNames` answers `as`, so this is the array path and the string path at once.
    @Test func aCallAnswersAnArrayOfStrings() throws {
        let bus = try SystemBus()
        let reply = try bus.call(
            destination: "org.freedesktop.DBus",
            path: "/org/freedesktop/DBus",
            interface: "org.freedesktop.DBus",
            method: "ListNames"
        )

        let names = try #require(reply.first)
        guard case let .array(items) = names else {
            Issue.record("ListNames should answer an array, got \(names)")
            return
        }
        #expect(items.count > 1)
        // Every bus has its own name on it, so this is a fact rather than a machine's quirk.
        #expect(items.contains(.string("org.freedesktop.DBus")))
    }

    /// **A string argument going out, which is the marshalling half.** `NameHasOwner` takes `s` and
    /// answers `b`, so a wrong signature is refused by the daemon rather than quietly accepted.
    @Test func aStringArgumentIsSentAndABooleanComesBack() throws {
        let bus = try SystemBus()
        func owned(_ name: String) throws -> Bool? {
            try bus.call(
                destination: "org.freedesktop.DBus",
                path: "/org/freedesktop/DBus",
                interface: "org.freedesktop.DBus",
                method: "NameHasOwner",
                arguments: [.string(name)]
            ).first?.flag
        }

        #expect(try owned("org.freedesktop.DBus") == true)
        #expect(try owned("au.com.tux.facet.nothing.owns.this") == false)
    }

    /// **A refusal keeps its D-Bus error name**, which is the half that matters: `org.bluez.Error.NotConnected`
    /// says something a human-readable string does not, and the radio branches on it.
    @Test func arefusalCarriesTheErrorName() throws {
        let bus = try SystemBus()
        do {
            _ = try bus.call(
                destination: "org.freedesktop.DBus",
                path: "/org/freedesktop/DBus",
                interface: "org.freedesktop.DBus",
                method: "NoSuchMethodExists"
            )
            Issue.record("a method that does not exist should not answer")
        } catch let failure as SystemBus.Failure {
            guard case let .callFailed(name, message) = failure else {
                Issue.record("expected callFailed, got \(failure)")
                return
            }
            #expect(name.hasPrefix("org.freedesktop.DBus.Error"), "got \(name)")
            #expect(!message.isEmpty)
        }
    }

    /// The nested shape BlueZ answers with: `a{oa{sa{sv}}}`, three levels of dictionary with variants at
    /// the bottom. Walking it wrongly is the failure this whole layer exists to prevent.
    @Test func theNestedObjectTreeIsWalkedToItsLeaves() throws {
        let bus = try SystemBus()
        let reply: [DBusValue]
        do {
            reply = try bus.call(
                destination: "org.bluez",
                path: "/",
                interface: "org.freedesktop.DBus.ObjectManager",
                method: "GetManagedObjects"
            )
        } catch {
            // BlueZ not running is not this test's business to fail over.
            Issue.record(Comment(rawValue: "org.bluez did not answer, so this machine cannot check it: \(error)"))
            return
        }

        let objects = try #require(reply.first?.members, "the reply should be a dictionary of object paths")
        #expect(objects["/org/bluez"] != nil, "the manager object is always there")

        // The adapter, found by the interface it carries rather than by assuming it is hci0.
        let adapter = objects.first { $0.value["org.bluez.Adapter1"] != nil }
        let properties = try #require(adapter?.value["org.bluez.Adapter1"]?.members)

        // A string, a boolean and an array of strings, each read from inside a variant -- which is every
        // property read the radio will do.
        let address = try #require(properties["Address"]?.text)
        #expect(address.count == 17, "a MAC address is six hex pairs and five colons: \(address)")
        #expect(properties["Powered"]?.flag != nil, "a boolean inside a variant")
        if case let .array(uuids)? = properties["UUIDs"] {
            #expect(uuids.allSatisfy { $0.text != nil }, "an array of strings inside a variant")
        }
    }

    /// **A byte array going out**, which no other test covers and which `WriteValue` is entirely made of.
    /// Sent to a path that does not exist: what is being checked is that libdbus accepted the argument and
    /// the refusal came back from BlueZ about the object, not about the message.
    @Test func aByteArrayArgumentIsAcceptedByTheWire() throws {
        let bus = try SystemBus()
        do {
            _ = try bus.call(
                destination: "org.bluez",
                path: "/org/bluez/hci0/dev_00_00_00_00_00_00/service0001/char0002",
                interface: "org.bluez.GattCharacteristic1",
                method: "WriteValue",
                arguments: [.bytes([0x10, 0x01, 0x02]), .dictionary([:])]
            )
            Issue.record("that object does not exist, so the call should be refused")
        } catch let failure as SystemBus.Failure {
            guard case let .callFailed(name, _) = failure else {
                Issue.record("expected callFailed, got \(failure)")
                return
            }
            // The refusal must be about the object or the method, never about the arguments: an
            // `org.freedesktop.DBus.Error.InvalidArgs` here would mean the marshalling was wrong.
            #expect(
                !name.contains("InvalidArgs"),
                "the byte array and options dictionary should have marshalled cleanly, got \(name)"
            )
        }
    }

    /// **The signal path, which is the one the app's core function rides on**: a face turn is a
    /// `PropertiesChanged` carrying a byte array. This triggers its own signal rather than waiting for a
    /// device to advertise, so it does not depend on anything being in range: toggling discovery makes
    /// BlueZ publish `Discovering` on the adapter, which is the same shape by a different name.
    @Test func aSignalArrivesAndItsValuesAreTyped() throws {
        let bus = try SystemBus()
        let adapter: String
        do {
            let reply = try bus.call(
                destination: "org.bluez",
                path: "/",
                interface: "org.freedesktop.DBus.ObjectManager",
                method: "GetManagedObjects"
            )
            let objects = reply.first?.members ?? [:]
            guard let found = objects.first(where: { $0.value["org.bluez.Adapter1"] != nil })?.key else {
                Issue.record("this machine has no BlueZ adapter, so the signal path cannot be checked here")
                return
            }
            adapter = found
        } catch {
            Issue.record(Comment(rawValue: "org.bluez did not answer: \(error)"))
            return
        }

        try bus.addMatch(
            "type='signal',sender='org.bluez',interface='org.freedesktop.DBus.Properties',path='\(adapter)'"
        )

        func discovery(_ method: String) {
            // Either may be refused for being already in that state, which is not this test's subject.
            _ = try? bus.call(
                destination: "org.bluez", path: adapter, interface: "org.bluez.Adapter1", method: method
            )
        }
        discovery("StopDiscovery")
        discovery("StartDiscovery")
        defer { discovery("StopDiscovery") }

        // Pump until the adapter says it is discovering, or give up. Ten quarter-second waits is far
        // longer than BlueZ takes and still bounded, which is what the suite's time limit wants.
        var discovering: Bool?
        for _ in 0 ..< 10 where discovering == nil {
            guard let signal = bus.nextSignal(waitingMilliseconds: 250) else { continue }
            // **Not every signal that arrives is a match hit**: the bus sends `NameAcquired` to a new
            // connection whatever it has asked for, so a caller filters by what it wanted rather than
            // trusting that anything arriving is its own.
            guard signal.member == "PropertiesChanged",
                  signal.arguments.first?.text == "org.bluez.Adapter1" else { continue }
            discovering = signal.arguments.dropFirst().first?["Discovering"]?.flag
        }

        #expect(discovering == true, "the adapter should have published Discovering as a boolean in a variant")
    }
}
#endif
