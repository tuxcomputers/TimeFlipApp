# Driving the cube from BlueZ

[← Back to README](../README.md)

**Host-stack notes, not firmware.** What the *cube* does is
[`timeflip2-firmware-observations.md`](timeflip2-firmware-observations.md), and a fact belongs there only if it is
about the hardware. This file is the other half: what **BlueZ** does, where it differs from CoreBluetooth, and which
of those differences will cost somebody an afternoon. It exists because the Linux port has to rebuild the four files
that `import CoreBluetooth` -- `BluetoothRadio`, `DeviceLogin`, `TimeFlipUUIDs`, `BLETrace` -- against a stack whose
shape is not the same.

Everything here was measured on **Linux Mint 22.3, BlueZ 5.72, adapter `hci0`, 2026-09-06**, against the cube
described in the observations file. `scripts/linux-ble-probe.py` is the run: it walks the same sequence
`DeviceLogin` does and prints what came back, and it is the reference implementation for the D-Bus calls below.

## It works

The question this file was opened to answer. Scan, connect, resolve, log in on the vendor default PIN, read every
characteristic the app reads, subscribe to faces, and receive sixteen turns of the cube live. Every stage passed
(evidence rows 20001 to 20051). Nothing about this hardware needs macOS.

Two things that are *easier* here, both worth knowing before designing around the Mac's constraints:

- **No pairing agent.** `Paired: 0`, `Bonded: 0`, on a cube the probe had just logged into and driven. The cube's
  authentication is entirely the app-level PIN written to the password characteristic, so there is no OS-level
  bonding dance to reproduce and no agent to register.
- **No `sudo`.** Discovery, connection, reads, writes and notifications all ran as an ordinary desktop user.

## And it works from Swift, which is the thing that was still an assumption

**2026-09-07, this Linux box, against the cube after a factory reset.** Everything above was the Python
probe; this is `FacetCore`'s own code doing the same sequence over `libdbus`, in process, with no
subprocess and no Python.

| Stage | What came back |
|---|---|
| Discovery | the cube found by **`DeviceScanRules`**, the app's own rule, unchanged from the Mac's side |
| Its identity here | `TimeFlip v2.0` at `E8:DB:D8:CF:F9:0F`, as the identifier `FACE7000-0000-0000-0000-E8DBD8CFF90F` |
| Connect | `ServicesResolved: true`, `Paired: false` |
| Enumeration | **16 characteristics**, each matched to the app's own UUID spelling |
| Login | the vendor PIN as six ASCII digits, and the command result read back `02` |
| Reads | `DI_LABS`, `2.0`, `FW_v3.64`, battery `100%`, facing `0c` |
| Notifications | values pushed as `PropertiesChanged` signals carrying `ay`, read as `[UInt8]` |

**The address survived the factory reset.** `E8:DB:D8:CF:F9:0F` before and after, which `systems-info.md`
had recorded as untested -- and worth knowing because it is a *random*-type address, the kind the
specification allows a device to change.

**Two things this run did not prove**, said plainly because the run looks more complete than it is:

- **A face turn was not observed.** The two values pushed were the login verdict and the initial `faces`
  value on subscribe, both arriving immediately and both `0c`. So the notification path is proven with
  real bytes from real hardware; that a *change* of face pushes a new value is still only the Python
  probe's finding (sixteen turns, evidence rows above), not this code's.
- **Nothing was written but the PIN.** No `0x10` status read, no pause, no lock, no colour. The write path
  is proven for six bytes to the password characteristic and no further.

## The mapping

| CoreBluetooth | BlueZ over D-Bus |
|---|---|
| `CBCentralManager` | `org.bluez.Adapter1` on `/org/bluez/hci0` |
| `scanForPeripherals(withServices:)` | `SetDiscoveryFilter` then `StartDiscovery` |
| `didDiscover` | `InterfacesAdded` on the ObjectManager, or poll `GetManagedObjects` |
| `CBPeripheral` | `org.bluez.Device1` |
| `connect(_:)` | `Device1.Connect()` |
| `didDiscoverServices` / `didDiscoverCharacteristics` | wait for `Device1.ServicesResolved` to go true |
| `CBCharacteristic` | `org.bluez.GattCharacteristic1` |
| `readValue(for:)` | `ReadValue({})` |
| `writeValue(_:for:type: .withResponse)` | `WriteValue(bytes, {"type": "request"})` |
| `writeValue(_:for:type: .withoutResponse)` | `WriteValue(bytes, {"type": "command"})` |
| `setNotifyValue(true, for:)` | `StartNotify()`, then `PropertiesChanged` carrying `Value` |
| `peripheral.identifier` | `Device1.Address`, and see finding 8 |

## The traps, in the order they bite

### 1. Do not filter discovery on the service UUID

`SetDiscoveryFilter` with `UUIDs: [f1196f50-…]` finds **nothing**, because the cube does not advertise its service
UUID -- finding 12, and the measurement is there. Scan with `Transport: le` and no UUID filter, and match on the
name as `DeviceScanRules.vendorName` does.

This is the one that looks most like a hardware fault and is not. Twenty seconds of silence, no error, cube on the
desk.

### 2. `Operation already in progress` is not a refusal

`Device1.Connect()` immediately after `StopDiscovery()` fails with
`org.bluez.Error.Failed: Operation already in progress` on a cube that is perfectly reachable. BlueZ has started its
own connection attempt off the back of discovery, and a second `Connect()` on top of it is the error rather than the
cause.

**Let discovery settle, then treat that error as a signal to wait rather than to give up**: poll `Device1.Connected`
until it goes true and carry on. Only a wait that expires is a failure. There is no CoreBluetooth equivalent of this
and nothing in the app's own driver anticipates it.

### 3. Read after `ServicesResolved`, not after `Connect()` returns

`Connect()` returning means the link is up, not that the GATT database is known. `Device1.ServicesResolved` going
true is the moment that corresponds to CoreBluetooth calling back with discovered services, and reading a
characteristic before it lands is how a probe finds nothing on a cube that is fine. Here it took about three seconds
from `Connect()` to resolved.

### 4. BlueZ caches the GATT tree and the name, per address

The cube renames itself (finding 1), and BlueZ keeps what it last saw against the address. A stale cache is a real
way to get a wrong answer that looks like a firmware fault. `Adapter1.RemoveDevice(path)` drops the record and forces
a fresh discovery -- `scripts/linux-ble-probe.py --clear-cache` does exactly that.

This cuts the other way too, and usefully: a Linux host is **a second BLE central with no cached record of the
device**, which is precisely what finding 1 says is needed to settle whether a rename applies immediately or is
deferred. That experiment has not been run.

### 5. UUIDs come back lowercase, and 16-bit ones come back expanded

BlueZ reports every UUID as a lowercase 128-bit string, so the app's `"180A"` arrives as
`0000180a-0000-1000-8000-00805f9b34fb`. Compare case-insensitively and expand the short forms, or the Device
Information service will look absent.

## What the cube offered that the app names nowhere

The probe resolved five services, of which the app knows three. The other two:

- **`0x1801`**, Generic Attribute, with `0x2A05` Service Changed as indicate-only. Standard, and only interesting
  because a client that subscribed to it would be told when the GATT tree changes.
- **`0xFE59`**, the **Nordic DFU service**, with characteristic `8ec90004-f315-4f60-9fb8-838830daea50` as
  write-and-indicate. This is presumably how the vendor's own app flashes firmware. Nothing in this app touches it
  and nothing should: the README is explicit that only the vendor's app can flash firmware, and this is a note about
  what is on the device rather than an invitation.

## Running the probe

```sh
python3 scripts/linux-ble-probe.py                 # scan, connect, log in, read, watch faces for 30s
python3 scripts/linux-ble-probe.py --pin 123456    # a cube this app has already set a PIN on
python3 scripts/linux-ble-probe.py --clear-cache   # drop the BlueZ record first, per trap 4
python3 scripts/linux-ble-probe.py --watch-seconds 0   # skip the stage that needs a hand on the cube
```

Needs `python3-dbus` and `python3-gi`, both of which are on a stock Mint desktop. It exits non-zero if any stage
failed, and it names the stage. **The cube holds one connection at a time**, so quit Facet on the Mac first --
that is the likeliest way to waste a run.
