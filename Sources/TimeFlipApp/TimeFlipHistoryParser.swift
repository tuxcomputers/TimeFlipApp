import Foundation

enum TimeFlipHistoryParser {
    static func parse(_ data: Data) -> TimeFlipHistoryEntry? {
        guard data.count >= 17 else { return nil }
        // Copy to a zero-based array so `data` slices (nonzero startIndex) parse correctly.
        let bytes = [UInt8](data)

        let eventNumber = UInt32(bigEndianBytes: Array(bytes[0..<4]))
        // Treat zero eventNumber frames as sentinel-like; ignore and let caller decide.
        if eventNumber == 0 { return nil }
        let rawSide = bytes[4]
        if rawSide == 66 { return nil } // accelerometer error sentinel from spec

        let isPauseEvent = rawSide >= 128
        let facetID = isPauseEvent ? rawSide &- 128 : rawSide
        guard TimeFlipConstants.isValidFacetID(facetID) else { return nil }

        let timestamp = UInt64(bigEndianBytes: Array(bytes[5..<13]))
        // Vendor doc (2020) used 5-byte LE; newer firmware uses 4-byte BE at bytes 13-16.
        let durationBytes = Array(bytes[13..<min(bytes.count, 17)])
        let durationSeconds = UInt64.durationTolerant(durationBytes)

        let startedAt = Date(timeIntervalSince1970: TimeInterval(timestamp))
        let duration = TimeInterval(durationSeconds)

        return TimeFlipHistoryEntry(
            eventNumber: eventNumber,
            facetID: facetID,
            startedAt: startedAt,
            duration: duration,
            isPaused: isPauseEvent
        )
    }
}

extension UInt32 {
    init(bigEndianBytes bytes: [UInt8]) {
        var value: UInt32 = 0
        for byte in bytes {
            value = (value << 8) | UInt32(byte)
        }
        self = value
    }
}

extension UInt64 {
    init(bigEndianBytes bytes: [UInt8]) {
        var value: UInt64 = 0
        for byte in bytes {
            value = (value << 8) | UInt64(byte)
        }
        self = value
    }

    init(littleEndian5 bytes: [UInt8]) {
        var value: UInt64 = 0
        for (shift, byte) in bytes.enumerated() {
            value |= UInt64(byte) << (8 * shift)
        }
        self = value
    }

    /// Decode vendor 5-byte little-endian durations but tolerate firmware that encodes as big-endian in first 4 bytes.
    static func durationTolerant(_ bytes: [UInt8]) -> UInt64 {
        // Prefer 4-byte big-endian at bytes 13-16 (observed on firmware shipping 2026-01).
        let big4 = UInt64(bigEndianBytes: Array(bytes.prefix(4)))
        let little4 = UInt64(littleEndian4: Array(bytes.prefix(4)))
        let little5 = bytes.count >= 5 ? UInt64(littleEndian5: bytes) : 0
        let big5 = bytes.count >= 5 ? UInt64(bigEndianBytes: bytes) : 0

        let candidates = [big4, little4, little5, big5].filter { $0 > 0 }
        return candidates.min() ?? 0
    }

    init(littleEndian4 bytes: [UInt8]) {
        var value: UInt64 = 0
        for (shift, byte) in bytes.enumerated() {
            value |= UInt64(byte) << (8 * shift)
        }
        self = value
    }
}
