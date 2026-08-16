import Foundation

/// How a raw duration in seconds becomes the whole number of seconds a format string prints.
enum DurationRounding {
    /// For a live, ticking value: the seconds shown are never ahead of what has actually elapsed.
    case truncate
    /// For a static historical sum: a 59.6-second total reads as a minute, not one second short of
    /// what was actually logged.
    case round
}

/// The `H:MM`/`H:MM:SS` duration format shared by the menu bar (`MenuBarController`) and the
/// Report tab (`ReportView`), so a span can never read one way in one place and another way in the
/// other. Hours are unpadded below 10 (`1:23`) but keep two digits once double-digit (`12:23`), and
/// are never dropped even when zero (`0:07`, not `7`), which would be ambiguous against the hours
/// in a figure beside it.
enum DurationFormat {
    static func hoursMinutesSeconds(
        _ duration: TimeInterval,
        rounding: DurationRounding,
        showingSeconds: Bool
    ) -> String {
        let totalSeconds: Int
        switch rounding {
        case .truncate: totalSeconds = Int(duration)
        case .round: totalSeconds = Int(duration.rounded())
        }
        let hours = totalSeconds / Int(TimeConstants.secondsPerHour)
        let minutes = (totalSeconds % Int(TimeConstants.secondsPerHour)) / Int(TimeConstants.secondsPerMinute)
        if showingSeconds {
            let seconds = totalSeconds % Int(TimeConstants.secondsPerMinute)
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", hours, minutes)
    }
}
