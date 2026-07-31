import Foundation

/// A face's task configuration, as carried by protocol commands 0x13 (write) and 0x14 (read).
///
/// This is device state the app does not otherwise use: the TimeFlip can run a per-face countdown
/// (the vendor calls it pomodoro mode) entirely on its own, and announces when it wants the host to
/// push parameters via the `taskParametersSyncRequired` system-state notification. Until these
/// commands existed the app decoded that notification and ignored it.
///
/// Field layout, from `docs/TimeFlip2 BLE Protocol v4.3.md`:
///
///     write  0x13 0xNN 0xPP 0xTT 0xTT 0xTT 0xTT
///     read   0x14 0xNN
///     reply  0x14 0xNN 0xPP 0xTT 0xTT 0xTT 0xTT 0xCC 0xCC 0xCC 0xCC
///
/// `0xNN` face, `0xPP` mode, `0xTT…` the limit in seconds, `0xCC…` seconds elapsed since the timer
/// started. `elapsedSeconds` is therefore read-only: it comes back from the device and is not part
/// of what gets written, which is why it is not in `Equatable`'s idea of "the same configuration".
struct FaceTaskParameters: Sendable, Codable {
    /// The vendor spec defines 0 and 1 and explicitly reserves the rest ("and/or other modes that
    /// can applied in future"), so an unrecognised value is preserved rather than coerced -- a
    /// device on newer firmware shouldn't have its mode silently rewritten to `simple` by a
    /// read-modify-write.
    enum Mode: Sendable, Codable, Equatable {
        case simple
        case pomodoro
        case unknown(UInt8)

        init(rawValue: UInt8) {
            switch rawValue {
            case 0: self = .simple
            case 1: self = .pomodoro
            default: self = .unknown(rawValue)
            }
        }

        var rawValue: UInt8 {
            switch self {
            case .simple: return 0
            case .pomodoro: return 1
            case .unknown(let value): return value
            }
        }
    }

    var faceID: UInt8
    var mode: Mode
    /// Countdown limit in seconds. The spec only gives it meaning when `mode == .pomodoro`, but the
    /// device stores it regardless, so it is carried either way rather than zeroed.
    var limitSeconds: UInt32
    /// Seconds since the device started this face's timer. Device-reported; `nil` on a value being
    /// written, since 0x13 has no field for it.
    var elapsedSeconds: UInt32?

    init(faceID: UInt8, mode: Mode, limitSeconds: UInt32, elapsedSeconds: UInt32? = nil) {
        self.faceID = faceID
        self.mode = mode
        self.limitSeconds = limitSeconds
        self.elapsedSeconds = elapsedSeconds
    }

    /// A face with no countdown: what 0xFE restores everything to.
    static func simple(faceID: UInt8) -> FaceTaskParameters {
        FaceTaskParameters(faceID: faceID, mode: .simple, limitSeconds: 0)
    }

    /// The 6-byte 0x13 payload. Big-endian, matching every other multi-byte field in this protocol.
    func commandPayload() -> Data {
        Data([
            0x13,
            faceID,
            mode.rawValue,
            UInt8((limitSeconds >> 24) & 0xFF),
            UInt8((limitSeconds >> 16) & 0xFF),
            UInt8((limitSeconds >> 8) & 0xFF),
            UInt8(limitSeconds & 0xFF)
        ])
    }

    /// Parses a 0x14 reply. Returns nil rather than a half-filled value if the frame is the wrong
    /// shape, so a caller can't mistake a malformed response for a face with no task set.
    static func parse(_ response: Data) -> FaceTaskParameters? {
        // Re-index from zero: a Data slice off a read keeps its parent's startIndex, so subscripting
        // it directly reads the wrong bytes (or traps).
        let bytes = [UInt8](response)
        guard bytes.count >= 11, bytes[0] == 0x14 else { return nil }
        func beUInt32(_ offset: Int) -> UInt32 {
            (UInt32(bytes[offset]) << 24)
                | (UInt32(bytes[offset + 1]) << 16)
                | (UInt32(bytes[offset + 2]) << 8)
                | UInt32(bytes[offset + 3])
        }
        return FaceTaskParameters(
            faceID: bytes[1],
            mode: Mode(rawValue: bytes[2]),
            limitSeconds: beUInt32(3),
            elapsedSeconds: beUInt32(7)
        )
    }
}

extension FaceTaskParameters: Equatable {
    /// Compares the *configuration*, deliberately ignoring `elapsedSeconds`: that field is a running
    /// clock, so including it would make a value read a second apart compare unequal to itself and
    /// make "did the write take?" impossible to assert.
    static func == (lhs: FaceTaskParameters, rhs: FaceTaskParameters) -> Bool {
        lhs.faceID == rhs.faceID
            && lhs.mode == rhs.mode
            && lhs.limitSeconds == rhs.limitSeconds
    }
}
