import CGtk
import FacetCore
import Foundation

/// Makes Swift concurrency run under `gtk_main`.
///
/// **Without it, every `Task { @MainActor }` in the process silently never runs**, which is measured rather than
/// reasoned about (2026-09-19): pressing Connect on the App tab logged the press and the task body wrote nothing,
/// because Swift's main-actor executor enqueues to `DispatchQueue.main` and `gtk_main` drains neither that nor
/// `RunLoop.main`.
///
/// **It is the same fault `GLibScheduler` closed, in a second spelling.** Six core modules used to put a `Timer` on
/// `RunLoop.main`, which this loop does not run, so not one of them would ever have fired. That one was visible the
/// moment a clock did not tick. This one shows only where the app uses `async` -- which on this platform is the
/// Google half, sign-in and calendar sync, and nothing else. Neither is reachable without an account, so the app
/// ran for eight days with the whole of its concurrency inert and nothing to see.
///
/// **Nothing in the core changes, which is the point.** `CalendarSync.sweep` and `GoogleSignIn.run` are written
/// against the main actor and are right; what was missing was a platform making the main actor true. That is what
/// an adapter is for, and it is why this is nine lines in `FacetLinux` rather than a restructuring of two core
/// modules.
@MainActor
enum DispatchOnTheMainLoop {
    /// Attaches the dispatch main queue to GLib's default context. **Called once, before `gtk_main`**, and never
    /// undone: the queue lives as long as the process.
    ///
    /// **Before, not after.** A task enqueued while nothing is draining is not lost -- the queue keeps it -- but
    /// anything the app does at startup would then run in a burst at the first drain rather than when it was asked
    /// for, which is a different app.
    static func start(debugLog: DebugLog?) {
        let source = facet_drain_dispatch_on_the_main_loop()
        guard source != 0 else {
            // **Said rather than swallowed**: a process where this failed is one where the Google half does nothing
            // at all and says nothing about it, which is precisely the silence this exists to end.
            debugLog?.record(.launch, "The dispatch main queue could not be attached, so nothing async will run")
            return
        }
        debugLog?.record(.launch, "The dispatch main queue is attached to the main loop")
    }
}
