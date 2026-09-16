import CGtk
import Foundation

/// Swift closures connected to GTK signals, and kept alive for as long as the surface that connected them.
///
/// **A closure cannot cross into C**, which is the whole of why this exists: `g_signal_connect` takes a bare
/// function pointer and a `void *`, so the closure has to be boxed into a class, handed over as an `Unmanaged`
/// pointer, and held somewhere until the widget is destroyed. Doing that at each call site is four lines of
/// ceremony per control, and forgetting the holding is a handler that works until the first collection.
///
/// **One collection per surface, cleared when the surface rebuilds.** Every list in this window is rebuilt rather
/// than diffed -- the rows are read from the database each time, so they arrive whole -- and the handlers on the old
/// rows go with them.
///
/// **The widget is not passed to the closure**, deliberately: a closure that needs its entry or its expander
/// captures it, which is one thing to read instead of a cast from a pointer the callback was handed.
@MainActor
final class GtkSignals {
    private final class Action {
        let run: () -> Void
        init(_ run: @escaping () -> Void) { self.run = run }
    }

    private final class EventAction {
        let run: (UnsafeMutablePointer<GdkEvent>?) -> Bool
        init(_ run: @escaping (UnsafeMutablePointer<GdkEvent>?) -> Bool) { self.run = run }
    }

    private final class DrawAction {
        let run: (OpaquePointer?) -> Void
        init(_ run: @escaping (OpaquePointer?) -> Void) { self.run = run }
    }

    private var actions: [AnyObject] = []

    /// Connects a signal whose handler takes nothing but the widget: `clicked`, `toggled`, `activate`,
    /// `value-changed`.
    func connect(
        _ widget: UnsafeMutablePointer<GtkWidget>,
        _ signal: String,
        _ run: @escaping () -> Void
    ) {
        let action = Action(run)
        actions.append(action)
        // **`assumeIsolated` rather than a hop, and it is sound rather than convenient.** GTK dispatches from
        // `gtk_main`, which runs on the thread that called `gtk_init` -- the main thread, because that is where
        // every type here may be used at all. Hopping instead would mean a control that acts one turn of the loop
        // after it was pressed. `MenuBar` says the same thing at its own call site.
        facet_on(widget, signal, { _, data in
            guard let data else { return }
            MainActor.assumeIsolated {
                Unmanaged<Action>.fromOpaque(data).takeUnretainedValue().run()
            }
        }, Unmanaged.passUnretained(action).toOpaque())
    }

    /// Connects an event signal -- `key-press-event`, `focus-out-event`, `delete-event` -- whose handler answers
    /// whether the event has been dealt with. `true` stops GTK passing it on, which for a key is what claims it.
    func connectEvent(
        _ widget: UnsafeMutablePointer<GtkWidget>,
        _ signal: String,
        _ run: @escaping (UnsafeMutablePointer<GdkEvent>?) -> Bool
    ) {
        let action = EventAction(run)
        actions.append(action)
        facet_on_event(widget, signal, { _, event, data in
            guard let data else { return 0 }
            return MainActor.assumeIsolated {
                Unmanaged<EventAction>.fromOpaque(data).takeUnretainedValue().run(event) ? 1 : 0
            }
        }, Unmanaged.passUnretained(action).toOpaque())
    }

    /// Connects `draw`, whose handler is handed a cairo context. Answers `false` to GTK always: what is drawn here
    /// is drawn *as well as* whatever the widget draws for itself, never instead of it.
    func connectDraw(
        _ widget: UnsafeMutablePointer<GtkWidget>,
        _ run: @escaping (OpaquePointer?) -> Void
    ) {
        let action = DrawAction(run)
        actions.append(action)
        facet_on_draw(widget, { _, context, data in
            guard let data else { return 0 }
            MainActor.assumeIsolated {
                Unmanaged<DrawAction>.fromOpaque(data).takeUnretainedValue().run(context)
            }
            return 0
        }, Unmanaged.passUnretained(action).toOpaque())
    }

    /// Forgets every closure. **Called as a surface throws its widgets away**, never while they are still on screen:
    /// a handler released under a live widget is a press that reaches a pointer to nothing.
    func removeAll() {
        actions.removeAll()
    }
}
