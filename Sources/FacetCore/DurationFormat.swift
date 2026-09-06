import Foundation

/// How a raw duration in seconds becomes the whole number of seconds a format string prints.
enum DurationRounding {
    /// For a live, ticking value: the seconds shown are never ahead of what has actually elapsed.
    case truncate
    /// For a static historical sum: a 59.6-second total reads as a minute, not one second short of what
    /// was actually logged.
    case round
}

/// The `H:MM`/`H:MM:SS` duration format, in one place so a span cannot read one way in the menu bar and
/// another way on a tab. Hours are unpadded below 10 (`1:23`) but keep two digits once double-digit
/// (`12:23`), and are never dropped even when zero (`0:07`, not `7`), which would be ambiguous against the
/// hours in a figure beside it.
///
/// Copied from the previous app: it is right, and rewriting it would land in the same place.
enum DurationFormat {
    private static let secondsPerMinute = 60
    private static let secondsPerHour = 3_600

    static func hoursMinutesSeconds(
        _ duration: TimeInterval,
        rounding: DurationRounding,
        showingSeconds: Bool
    ) -> String {
        // Negative durations cannot be printed sensibly and can only come from a clock that moved
        // backwards, so they read as zero rather than as "-0:-1".
        let seconds = max(0, duration)
        let totalSeconds: Int
        switch rounding {
        case .truncate: totalSeconds = Int(seconds)
        case .round: totalSeconds = Int(seconds.rounded())
        }
        let hours = totalSeconds / secondsPerHour
        let minutes = (totalSeconds % secondsPerHour) / secondsPerMinute
        if showingSeconds {
            return String(format: "%d:%02d:%02d", hours, minutes, totalSeconds % secondsPerMinute)
        }
        return String(format: "%d:%02d", hours, minutes)
    }
}
