import Foundation

/// Wake me in N seconds, once or over and over.
///
/// **The whole of what the core needs from a clock**, and deliberately no more: nothing here asks what time it
/// is, because `Date()` is the same Foundation on every platform and so is not a capability the platform
/// provides. What the platform provides is the *waiting*, and the six modules that wait all wanted the same two
/// sentences: call this back after so many seconds, and let me stop it before it happens.
///
/// **Why it is a port and not a shim.** On a Mac this is a `Timer` on `RunLoop.main`; on Linux under GTK it is
/// `g_timeout_add`; in a test it is a closure the test calls itself. Three different implementations rather than
/// three spellings of one, which is the test `CLAUDE.md` sets.
///
/// **It is also a fault being fixed rather than tidiness.** Six modules in this target built a `Timer` and added
/// it to `RunLoop.main`, and `FacetLinux` never runs `RunLoop.main`, so on Linux not one of those timers could
/// ever have fired: the history fetch, the low battery blink, the daily limit, the reconnect backoff, the settings
/// debounce and the quit deadline, all silently dead. The core cannot make that mistake through this, because
/// through this the core does not know what a run loop is.
@MainActor
package protocol Scheduler: AnyObject {
    /// Calls `tick` after `seconds`, once if `repeating` is false and every `seconds` until cancelled if it is.
    ///
    /// The answer is the handle to stop it with. Dropping the handle does **not** stop it: a repeating wake goes
    /// on until something calls `cancel`, which is what the run loop does on a Mac and what a caller has to plan
    /// for on any platform.
    ///
    /// - Parameter mayGroup: whether this wake can be moved to sit alongside other wake-ups rather than waking the
    ///   machine on its own. **Permission, not a number**: the core knows whether landing on the second matters,
    ///   which is a fact about the work, and the platform knows what to do with that, which is not. A Mac widens
    ///   the timer's tolerance; GTK has `g_timeout_add_seconds`, a different mechanism for the same permission.
    ///   The 300 second history fetch is the one caller that gives it.
    func wake(
        in seconds: TimeInterval,
        repeating: Bool,
        mayGroup: Bool,
        _ tick: @escaping @MainActor () -> Void
    ) -> ScheduledWake
}

extension Scheduler {
    /// One wake, `seconds` from now, wanted on time. What most callers mean.
    package func wake(
        in seconds: TimeInterval,
        _ tick: @escaping @MainActor () -> Void
    ) -> ScheduledWake {
        wake(in: seconds, repeating: false, mayGroup: false, tick)
    }

    /// A wake that repeats, wanted on time.
    package func wake(
        in seconds: TimeInterval,
        repeating: Bool,
        _ tick: @escaping @MainActor () -> Void
    ) -> ScheduledWake {
        wake(in: seconds, repeating: repeating, mayGroup: false, tick)
    }
}

/// A wake that has been arranged, and the one thing anybody wants to do with it afterwards.
///
/// **`cancel` is safe to call twice, and safe to call after the tick has already happened.** Both are ordinary:
/// a one-shot cancelled by a caller that does not track whether it already fired is the common case, not a bug to
/// guard against at every call site.
@MainActor
package protocol ScheduledWake: AnyObject {
    func cancel()
}
