import Foundation

struct DoubleTapParameters: Codable, Equatable, Sendable {
    var clickThreshold: UInt8
    var limit: UInt8
    var latency: UInt8
    var window: UInt8

    static var `default`: DoubleTapParameters {
        // Captured from a real device's actual registers (Tests/Bench/
        // device_register_snapshot.json), not an arbitrary guess -- see database/009_setting.sql.
        DoubleTapParameters(clickThreshold: 90, limit: 20, latency: 50, window: 50)
    }
}
