import Foundation

struct DoubleTapParameters: Codable, Equatable, Sendable {
    var clickThreshold: UInt8
    var limit: UInt8
    var latency: UInt8
    var window: UInt8

    static var `default`: DoubleTapParameters {
        // Conservative baseline values; real devices should be read via cmd 0x17.
        DoubleTapParameters(clickThreshold: 20, limit: 10, latency: 20, window: 40)
    }

    func clamped() -> DoubleTapParameters {
        DoubleTapParameters(
            clickThreshold: clickThreshold,
            limit: limit,
            latency: latency,
            window: window
        )
    }
}
