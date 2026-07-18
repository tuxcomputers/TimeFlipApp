import Foundation

enum ActivityRecordReason: String, Sendable {
    case paused
    case changed
    case stopped
    case history
}

struct ActivityRecord: Sendable {
    let activityName: String
    let startDate: Date
    let endDate: Date
    let duration: TimeInterval
    let reason: ActivityRecordReason
}

struct ActivityRecordFormatter {
    /// Fresh formatter per call keeps the shared state non-global to satisfy Sendable checks.
    static var iso8601: ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }

    static func formattedDuration(_ duration: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute, .second]
        formatter.unitsStyle = .positional
        formatter.zeroFormattingBehavior = [.pad]
        return formatter.string(from: duration) ?? "00:00:00"
    }
}
