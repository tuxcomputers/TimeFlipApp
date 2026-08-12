import Foundation

/// Debounces a device write: `schedule` cancels any pending write and reschedules it, so only the
/// action from the most recent call actually runs, after `delay` has passed with no further calls.
/// Used to let a setting whose value is edited live (auto-pause, LED brightness/blink, double-tap
/// params, a face's category) print and persist to the DB on every intermediate change while a held
/// stepper is moving, but only reach the physical device once the value has settled.
@MainActor
final class DeviceWriteDebouncer {
    /// How long a value must sit unchanged before it goes to the device. Every debounced write shares
    /// this, so the whole UI settles at one rate rather than each control having its own feel.
    static let defaultDelay: TimeInterval = 2.0

    private var task: Task<Void, Never>?

    func schedule(delay: TimeInterval = DeviceWriteDebouncer.defaultDelay, _ action: @escaping () async -> Void) {
        task?.cancel()
        task = Task {
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await action()
        }
    }

    /// Drops a pending write without running it, for when the same setting has just been written
    /// outright and the queued value is stale.
    func cancel() {
        task?.cancel()
        task = nil
    }
}
