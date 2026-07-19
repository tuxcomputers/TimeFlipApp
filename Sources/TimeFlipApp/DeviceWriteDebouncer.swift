import Foundation

/// Debounces a device write: `schedule` cancels any pending write and reschedules it, so only the
/// action from the most recent call actually runs, after `delay` has passed with no further calls.
/// Used to let a live-editable setting (auto-pause, LED brightness/blink, double-tap params) print
/// and persist to the DB on every intermediate change while a held stepper/slider is moving, but
/// only reach the physical device once the value has settled.
@MainActor
final class DeviceWriteDebouncer {
    private var task: Task<Void, Never>?

    func schedule(delay: TimeInterval = 1.0, _ action: @escaping () async -> Void) {
        task?.cancel()
        task = Task {
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await action()
        }
    }
}
