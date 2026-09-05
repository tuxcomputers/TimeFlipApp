import Foundation

/// What the cube says about itself on the system state characteristic (`F1196F56`): what it wants pushed back to it,
/// and whether its hardware is working.
///
/// **Values in, values out**, the split every device rules type here keeps. `DeviceLogin` asks the question,
/// `BluetoothRadio` files the answer, `main.swift` decides what to do about it, and this reads the four bytes.
///
/// **The archive's decoder, copied as it stands** (`TimeFlipEvent.TimeFlipSystemState`), and the
/// codes are worth keeping verbatim because they are the vendor's and nothing about them is derivable: `0x0100` for a
/// factory reset and `0x0202` for a flash fault are numbers somebody read out of a table, and re-deriving them means
/// reading the same table again. What is dropped is the four sync states this app has nothing to push for yet -- they
/// are still decoded and still named, because a state the app cannot act on is still a state worth putting in the log.
///
/// **Why it exists at all.** The rebuild subscribed to this characteristic from the start and had no handler, so every
/// notification was traced and dropped. That is worse than not subscribing: the cube announces a factory reset here,
/// and it announces a **flash memory fault** here, and history lives in flash -- so a cube that has quietly stopped
/// recording says so on this characteristic and the app had no way to hear it.
enum DeviceSystemStateRules {
    /// What the cube wants the app to do.
    enum CubeSyncState: Equatable {
        case ok
        /// It has been put back to the factory, so whatever it held is gone.
        case factoryReset
        case timeRequired
        case faceColoursRequired
        case ledBrightnessRequired
        case blinkIntervalRequired
        case taskParametersRequired
        case autoPauseRequired
        /// A code the vendor has not published. **Kept rather than coerced to `ok`**: a newer firmware asking for
        /// something this app has never heard of is a fact, and reading it as "nothing to do" would hide it.
        case unknown(UInt16)
    }

    /// Whether the cube's own hardware is working.
    enum CubeHardwareState: Equatable {
        case ok
        case accelerometer
        /// **Where history is stored.** A cube reporting this records nothing and cannot say so any other way: its
        /// history reads come back empty, which is indistinguishable from a cube that has simply been reset.
        case flash
        case accelerometerAndFlash
        case unknown(UInt16)
    }

    struct State: Equatable {
        let cubeSyncState: CubeSyncState
        let cubeHardwareState: CubeHardwareState
        /// The raw halves, kept so a row in the log can name a code this app does not recognise.
        let rawSync: UInt16
        let rawHardware: UInt16

        /// Whether anything here is worth saying out loud.
        var isEverythingFine: Bool { cubeSyncState == .ok && cubeHardwareState == .ok }
    }

    /// Reads the four bytes, or `nil` for a payload that is not one.
    ///
    /// Two big-endian halves: the first says what wants syncing, the second says what is broken.
    static func state(from value: Data?) -> State? {
        guard let value, value.count >= 4 else { return nil }
        let bytes = [UInt8](value)
        let rawSync = UInt16(bytes[0]) << 8 | UInt16(bytes[1])
        let rawHardware = UInt16(bytes[2]) << 8 | UInt16(bytes[3])
        return State(
            cubeSyncState: cubeSyncState(rawSync),
            cubeHardwareState: cubeHardwareState(rawHardware),
            rawSync: rawSync,
            rawHardware: rawHardware
        )
    }

    private static func cubeSyncState(_ raw: UInt16) -> CubeSyncState {
        switch raw {
        case 0x0000: return .ok
        case 0x0100: return .factoryReset
        case 0x0201: return .timeRequired
        case 0x0202: return .faceColoursRequired
        case 0x0203: return .ledBrightnessRequired
        case 0x0204: return .blinkIntervalRequired
        case 0x0205: return .taskParametersRequired
        case 0x0206: return .autoPauseRequired
        default: return .unknown(raw)
        }
    }

    private static func cubeHardwareState(_ raw: UInt16) -> CubeHardwareState {
        switch raw {
        case 0x0000: return .ok
        case 0x0201: return .accelerometer
        case 0x0202: return .flash
        case 0x0203: return .accelerometerAndFlash
        default: return .unknown(raw)
        }
    }

    /// How a state reads in the log, in words rather than codes.
    ///
    /// **Spelled out because the codes are the only thing the cube gives and they mean nothing to a reader.** An
    /// unrecognised one carries its number, which is the whole reason `unknown` keeps it.
    static func describe(_ state: State) -> String {
        "\(describe(state.cubeSyncState)), hardware \(describe(state.cubeHardwareState))"
    }

    private static func describe(_ sync: CubeSyncState) -> String {
        switch sync {
        case .ok: return "nothing to sync"
        case .factoryReset: return "it has been put back to the factory"
        case .timeRequired: return "it wants its time set"
        case .faceColoursRequired: return "it wants its face colours"
        case .ledBrightnessRequired: return "it wants its LED brightness"
        case .blinkIntervalRequired: return "it wants its blink interval"
        case .taskParametersRequired: return "it wants its task parameters"
        case .autoPauseRequired: return "it wants its auto-pause delay"
        case let .unknown(code): return String(format: "it is asking for something unpublished (0x%04X)", code)
        }
    }

    private static func describe(_ hardware: CubeHardwareState) -> String {
        switch hardware {
        case .ok: return "fine"
        case .accelerometer: return "ACCELEROMETER FAULT, so it cannot tell which face is up"
        case .flash: return "FLASH MEMORY FAULT, so it cannot record history"
        case .accelerometerAndFlash: return "ACCELEROMETER AND FLASH MEMORY FAULT"
        case let .unknown(code): return String(format: "an unpublished fault code (0x%04X)", code)
        }
    }
}
