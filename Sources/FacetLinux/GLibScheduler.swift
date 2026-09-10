import CGtk
import FacetCore
import Foundation

/// The Linux slot in the clock's square: a GLib timeout source on the default main context.
///
/// **The same job `RunLoopScheduler` does on the Mac**, and the port is what makes them interchangeable:
/// `HistoryTimer`, `LowBatteryWatch`, `DailyLimitWatch`, `DeviceReconnector`, `WriteDebounce` and
/// `QuitSequence` all wake through `Scheduler` and none of them can tell which of the two it got.
///
/// **Why this target needed one at all.** Those six modules used to build a `Timer` and add it to
/// `RunLoop.main`, which `gtk_main` does not run -- so on this platform not one of them would ever have
/// fired, silently and with nothing to see in a log. That is the fault `Scheduler` was made to close, and
/// it stays closed only while there is something on this side of it.
///
/// **`mayGroup` spends itself on `g_timeout_add_seconds`**, which is a different mechanism rather than a
/// tolerance: GLib aligns a second-granularity source with others already scheduled, so a 300 second
/// history fetch settles next to whatever else the process wakes for instead of waking it alone. That is
/// exactly what the port's doc comment offers the slot -- permission, and the platform decides what to
/// spend it on. A slot that ignored `mayGroup` entirely would still be correct.
///
/// **Not `@MainActor` for the compiler's sake.** GLib's default main context is the one `gtk_main` runs,
/// on the thread that called `gtk_init`, and GTK3 requires every call to come from that thread --
/// `MenuBar` says the same thing about itself. The isolation is that fact written where the compiler can
/// hold us to it.
@MainActor
final class GLibScheduler: Scheduler {
    func wake(
        in seconds: TimeInterval,
        repeating: Bool,
        mayGroup: Bool,
        _ tick: @escaping @MainActor () -> Void
    ) -> ScheduledWake {
        let wake = GLibWake(repeating: repeating, tick: tick)

        // **Retained across the C boundary and released by the destroy notify**, which is the whole reason
        // for the `_full` variants: GLib calls the notify when the source goes, whether it went because a
        // one-shot returned `G_SOURCE_REMOVE` or because `cancel` took it out. Retaining without one would
        // leak every wake this app ever arranges, and the app arranges one per reconnect attempt.
        let boxed = Unmanaged.passRetained(wake).toOpaque()
        let fire: @convention(c) (gpointer?) -> gboolean = { data in
            guard let data else { return 0 }
            // Sound rather than convenient, and the same argument `MenuBar` makes at its own callbacks:
            // this is dispatched from the main context, which only the main thread runs.
            return MainActor.assumeIsolated {
                Unmanaged<GLibWake>.fromOpaque(data).takeUnretainedValue().fire()
            }
        }
        let release: @convention(c) (gpointer?) -> Void = { data in
            guard let data else { return }
            Unmanaged<GLibWake>.fromOpaque(data).release()
        }

        // **Whole seconds only where grouping was asked for, and never zero of them.** `g_timeout_add_seconds`
        // with an interval of 0 is a source that fires as fast as the loop turns; a caller wanting less than a
        // second plainly does not want its wake aligned to one, so the millisecond source answers it instead.
        let identifier: guint
        if mayGroup, seconds >= 1 {
            identifier = g_timeout_add_seconds_full(
                G_PRIORITY_DEFAULT, guint(seconds.rounded()), fire, boxed, release
            )
        } else {
            let milliseconds = max(0, (seconds * 1000).rounded())
            identifier = g_timeout_add_full(
                G_PRIORITY_DEFAULT, guint(min(milliseconds, Double(guint.max))), fire, boxed, release
            )
        }

        // Safe after the fact rather than racing it: attaching a source does not turn the main loop, so
        // nothing can have fired between the call above and this line.
        wake.adopt(identifier)
        return wake
    }
}

/// One arranged wake: the identifier GLib gave it, and whether the source is still there.
///
/// **The flag is what makes `cancel` safe to call twice and safe to call after a one-shot has fired**, which
/// is what `ScheduledWake` promises. It is not defensive tidying: `g_source_remove` on an identifier GLib has
/// already reclaimed logs a critical, and worse, identifiers are reused -- so a stale one could remove a
/// source belonging to something else entirely. `DeviceReconnector` cancels handles it does not track the
/// state of, so this is the ordinary path rather than the odd one.
@MainActor
private final class GLibWake: ScheduledWake {
    private let repeating: Bool
    private let tick: @MainActor () -> Void
    private var identifier: guint?

    init(repeating: Bool, tick: @escaping @MainActor () -> Void) {
        self.repeating = repeating
        self.tick = tick
    }

    func adopt(_ identifier: guint) {
        self.identifier = identifier
    }

    /// Answers GLib with `G_SOURCE_CONTINUE` (1) or `G_SOURCE_REMOVE` (0), spelled as the numbers because
    /// both are macros and Swift does not see a macro.
    func fire() -> gboolean {
        // Cleared *before* the tick, so a one-shot whose own tick cancels it -- which is what a module doing
        // its work and tidying up looks like -- does not reach for an identifier GLib is about to reclaim.
        if !repeating { identifier = nil }
        tick()
        return repeating ? 1 : 0
    }

    func cancel() {
        guard let identifier else { return }
        self.identifier = nil
        g_source_remove(identifier)
    }
}
