// **Guarded because what it tests is in `FacetLinux` now**, moved there on 2026-09-10 so the core holds no
// adapter (`CLAUDE.md`, *The core is platform-blind*). `CDBus` is only in the package on Linux, so on macOS this
// file compiles to nothing, which is the same answer it always gave: there is no D-Bus here to test against.
#if canImport(CDBus)
import FacetLinux
import Foundation
import Testing
@testable import FacetCore

/// `BlueZAddress`: carrying a Bluetooth address inside the `UUID` this app is written around.
///
/// **The round trip is the whole contract.** The identifier has to be the same on every launch for the
/// same cube, and the address has to come back out of it to make a D-Bus call with -- so these check both
/// directions and the case that must fail, which is an identifier this did not make.
@Suite
struct BlueZAddressTests {
    /// The cube on the Linux box, from `docs/systems-info.md`.
    private let cube = "E8:DB:D8:CF:F9:0F"

    @Test func anAddressGoesInAndComesBackOut() throws {
        let identifier = try #require(BlueZAddress.identifier(forAddress: cube))
        #expect(BlueZAddress.address(fromIdentifier: identifier) == cube)
    }

    @Test func theSameCubeIsTheSameIdentifierEveryTime() throws {
        // What `device_uuid` depends on: a pairing written on one launch has to still name this cube on
        // the next, and nothing about the mapping may depend on when it was asked.
        let first = try #require(BlueZAddress.identifier(forAddress: cube))
        let second = try #require(BlueZAddress.identifier(forAddress: cube))
        #expect(first == second)
        #expect(BlueZAddress.identifier(forAddress: "E8:DB:D8:CF:F9:0E") != first, "a different cube")
    }

    @Test func theAddressComesBackInUpperCaseHoweverItWentIn() throws {
        // BlueZ answers upper case, so that is what a call should be made with.
        let identifier = try #require(BlueZAddress.identifier(forAddress: "e8:db:d8:cf:f9:0f"))
        #expect(BlueZAddress.address(fromIdentifier: identifier) == cube)
    }

    /// **A `device_uuid` written on the Mac is a valid UUID that names nothing here**, and answering an
    /// address for it would aim a D-Bus call at six bytes of somebody else's identifier.
    @Test func anIdentifierFromSomewhereElseIsRefused() throws {
        let macsOwn = try #require(UUID(uuidString: "FA1DDE60-5DBB-D5E9-B53C-881E16916B5E"))
        #expect(BlueZAddress.address(fromIdentifier: macsOwn) == nil)
        #expect(!BlueZAddress.isBlueZIdentifier(macsOwn))
        #expect(BlueZAddress.isBlueZIdentifier(try #require(BlueZAddress.identifier(forAddress: cube))))
    }

    @Test func somethingThatIsNotAnAddressIsRefusedRatherThanPadded() {
        for bad in ["", "E8:DB:D8:CF:F9", "E8:DB:D8:CF:F9:0F:11", "E8-DB-D8-CF-F9-0F", "ZZ:DB:D8:CF:F9:0F",
                    "E8:DB:D8:CF:F9:0", "not an address"] {
            #expect(BlueZAddress.identifier(forAddress: bad) == nil, "should refuse \(bad)")
            #expect(BlueZAddress.addressBytes(bad) == nil, "should refuse \(bad)")
        }
    }

    @Test func theDevicePathIsBlueZsOwnShape() {
        #expect(
            BlueZAddress.devicePath(adapter: "/org/bluez/hci0", address: cube)
                == "/org/bluez/hci0/dev_E8_DB_D8_CF_F9_0F"
        )
        #expect(BlueZAddress.devicePath(adapter: "/org/bluez/hci0", address: "rubbish") == nil)
    }
}
#endif
