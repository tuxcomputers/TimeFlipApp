import CGtk
import FacetCore
import Foundation

/// The status item, on the desktop's notification area.
///
/// **The Linux half of `MenuBarController`**, and the same shape as far as it goes: the app's logo in the
/// bar, a label beside it saying what is being timed, and a menu that opens on it. What draws it is an
/// `AppIndicator`, which is the tray protocol every desktop here understands -- MATE through
/// `xapp-sn-watcher`, and anything else implementing `org.kde.StatusNotifierWatcher`.
///
/// **Not in the accessibility tree, and that is measured rather than assumed** (2026-09-08, on the Linux
/// box): an application node has its windows as children and never its indicator, exactly as the macOS
/// status item is absent from `AXMenuBar`. A scripted check reaches this over D-Bus instead --
/// `com.canonical.dbusmenu`'s `GetLayout` reads the items and `Event` chooses one. See
/// `docs/linux-port.md`, which also records what `GetLayout` does **not** carry: a menu item crosses as its
/// label and whether it is enabled, and no identifier travels with it.
///
/// **Nothing here holds what it shows.** The label is asked for on every tick and the menu is asked for on
/// every tick beside it, both from closures that go to the database -- which is `CLAUDE.md`'s first rule, and
/// the reason the menu cannot come to disagree with the Faces tab about what is being timed.
///
/// **The tick is what redraws the menu, and that is forced rather than chosen** (2026-09-13). This used to
/// rebuild on the `GtkMenu`'s `show` signal, which is the Linux answer to `NSMenuDelegate.menuNeedsUpdate`
/// and would have been the right one. Measured on this box: a panel opening the menu calls
/// `com.canonical.dbusmenu`'s `AboutToShow`, which reaches no signal on the widget at all, and the one
/// `show` a `GtkMenu` behind an `AppIndicator` ever emits is emitted by `app_indicator_set_menu` itself --
/// before this file had even connected its handler. So the menu was built once, at launch, and never again:
/// it went on offering *Pair a cube* under a paired, connected app, with Pause and Lock insensitive over a
/// live cube. There is no interception to be had, the `DbusmenuServer` being libayatana-appindicator's own,
/// so the menu is re-read on the clock like the label.
///
/// **It decides nothing, as of 2026-09-11.** What the line says is `StatusItemReadout`'s, which is the core module
/// that also holds the first-reading latch, the tick decision and the two `debug_log` rows a change is worth; what
/// is in the menu is `StatusItemMenu`'s. This file predated all of that and had been deciding its own version of
/// both. The macOS side went from 679 lines to 518 making the same move, and what is left there is `NSStatusItem`
/// and drawing; what is left here is `AppIndicator` and drawing.
///
/// **What it does still decide is how to draw a glyph**, and that is genuinely this platform's: `StatusItemTitle`
/// answers in SF Symbol names, which mean nothing to a GTK panel, so `glyph(for:)` below is the rendering and not
/// the decision. Colour is the other half of that and this platform has none: an `AppIndicator` label is plain
/// text. The colours are still *decided* -- and still written to `debug_log` by the readout, which is the only way
/// a scripted check ever sees them on either platform.
///
/// **`@MainActor`, and GTK is the reason rather than the compiler.** GTK3 is not thread-safe: every call
/// has to come from the thread that called `gtk_init`, and `gtk_main` runs its loop on that same thread.
/// So the isolation is not an accommodation made to satisfy `DebugLog` -- it is what was already true,
/// written down where the compiler can hold us to it.
@MainActor
final class MenuBar {
    /// What a menu item does when it is chosen. Boxed into a class so it survives as an
    /// `Unmanaged` pointer across the C boundary, which cannot carry a Swift closure directly.
    private final class Action {
        let run: () -> Void
        init(_ run: @escaping () -> Void) { self.run = run }
    }

    private let indicator: UnsafeMutablePointer<AppIndicator>
    private let menu: UnsafeMutablePointer<GtkWidget>
    private let debugLog: DebugLog?

    /// **Injected rather than reached for**, which is what makes the tick above the same one the macOS status
    /// item uses. `MenuBarController` went the same way when the clock became a port: the last hand-rolled
    /// timer in that target went with it.
    private let scheduler: Scheduler
    /// Held so the repaint can be stopped, which nothing does yet -- the tick lives as long as the process.
    /// Dropping it would not stop it either way, `ScheduledWake` being explicit that a repeat runs until it
    /// is cancelled.
    private var repaint: ScheduledWake?

    /// What the line should say, decided in the core and asked here once a second.
    private let readout: StatusItemReadout

    /// What is in the menu, asked again as it opens. **A closure rather than a `StatusItemMenu`**, because this
    /// platform's composition root puts lines of its own around the shared ones: a list of today's totals, and the
    /// pairing control that stands in for a Device tab. Those are `main.swift`'s to add and this file's to draw.
    private let items: @MainActor () -> [StatusItemMenu.Item]

    /// The widgets and boxes making up the menu as it currently stands, destroyed and rebuilt together.
    /// **Not a copy of anything true** -- it is what GTK was handed, kept only so it can be taken back.
    private var shown: [UnsafeMutablePointer<GtkWidget>] = []
    private var actions: [Action] = []

    /// The lines GTK is currently drawing, for the one question the tick asks: is what it should say now
    /// different from what it is saying.
    ///
    /// **Not a copy of anything true either**, and it is the same kind of value `shown` is: the answer is read
    /// from `items()` every tick, and this is only what the panel was last handed. What it buys is that the
    /// panel is not handed a fresh layout once a second for no reason -- libdbusmenu tells its client the
    /// layout changed, and a client rebuilding a menu under somebody's pointer is worse than the second it
    /// saves.
    ///
    /// **In practice it rebuilds rarely, and that is worth knowing rather than assuming either way.** Measured
    /// against the cube 2026-09-13: with a category being timed for ten minutes the layout did not change once,
    /// because the totals in this menu are `TimeEntryStore.totals`, which counts segments that have *finished*.
    /// The ticking figure is the bar's label, which is not part of the menu. So a rebuild happens when the cube
    /// connects or goes, when a segment closes, and when the categories change -- which is what a menu opened by
    /// hand would have been rebuilt for anyway.
    private var handedOver: [Line] = []

    /// One drawn line, reduced to what a reader can tell apart. **Not `StatusItemMenu.Item`**, which carries a
    /// closure and so cannot be compared -- and the closures are all re-entrant reads of the table, so what
    /// changes between one tick and the next is always one of these three.
    private struct Line: Equatable {
        let title: String
        let isSeparator: Bool
        let isChoosable: Bool
    }

    init(debugLog: DebugLog?,
         scheduler: Scheduler,
         readout: StatusItemReadout,
         items: @escaping @MainActor () -> [StatusItemMenu.Item]) {
        self.debugLog = debugLog
        self.scheduler = scheduler
        self.readout = readout
        self.items = items

        // `nil, nil` rather than the real argv: GTK's own switches are not this app's, and passing them
        // through would let `--display` reach it from a command line meant for something else.
        gtk_init(nil, nil)
        menu = gtk_menu_new()

        // **The app's own logo, found the way GTK finds icons rather than by opening a file.**
        // `app_indicator_new_with_path` adds the directory to the icon theme's search path and then asks
        // for `facet` by name, which is how the panel gets to re-ask for it at whatever size and scale the
        // display turns out to want -- a 22-point bar and a 44-point one on a HiDPI screen are two
        // different requests, and handing over one rendered bitmap answers only the first.
        //
        // `facet.svg` is `Facet.small.svg`, the bolder of the two and drawn for small sizes; it is still
        // legible at 22 points, which is what a MATE panel asks for. GTK renders SVG through `librsvg`'s
        // gdk-pixbuf loader, which is present on this machine -- checked rather than assumed, because
        // without it the icon silently falls back to nothing at all.
        //
        // **Falling back out loud.** `Bundle.module` resolves beside the executable, so a binary installed
        // without `Facet_FacetLinux.resources` next to it has no logo to show. That is the same trap the
        // DDL sits behind, and it is the kind of thing that would otherwise be noticed as "the icon looks
        // wrong" months later rather than as a missing file now.
        if let resources = Bundle.module.resourcePath,
           FileManager.default.fileExists(atPath: resources + "/facet.svg") {
            indicator = app_indicator_new_with_path("facet", "facet",
                                                    APP_INDICATOR_CATEGORY_APPLICATION_STATUS,
                                                    resources)
        } else {
            debugLog?.record(.launch, "The logo was not found beside the binary, so the menu bar is using a stock icon")
            indicator = app_indicator_new("facet", "indicator-messages",
                                          APP_INDICATOR_CATEGORY_APPLICATION_STATUS)
        }
        app_indicator_set_status(indicator, APP_INDICATOR_STATUS_ACTIVE)
    }

    /// Reads what the menu should say and rebuilds it if that is not what it is saying.
    ///
    /// **The read always happens; only the drawing is conditional.** `items()` goes to the database, so this
    /// asks the same question the label does and at the same moment. What is skipped when the answer has not
    /// moved is throwing eleven widgets away and building eleven more, which is work for GTK and a layout
    /// change for whatever panel is drawing it.
    private func rebuildIfChanged() {
        let wanted = items()
        let lines = wanted.map {
            Line(title: $0.title, isSeparator: $0.isSeparator, isChoosable: $0.choose != nil)
        }
        guard lines != handedOver else { return }
        handedOver = lines
        rebuild(from: wanted)
    }

    /// Throws away the menu as it stands and builds it again from what was just read.
    ///
    /// **Rebuilt rather than edited.** Working out which rows changed and patching them is how a menu comes
    /// to show a category that was retired ten seconds ago: the rows are cheap and the question "what
    /// should be here now" has one answer, which is what `items()` returned.
    private func rebuild(from wanted: [StatusItemMenu.Item]) {
        for widget in shown { gtk_widget_destroy(widget) }
        shown.removeAll()
        actions.removeAll()

        for item in wanted {
            let widget: UnsafeMutablePointer<GtkWidget>
            if item.isSeparator {
                widget = gtk_separator_menu_item_new()
            } else {
                widget = gtk_menu_item_new_with_label(item.title)
                if let choose = item.choose {
                    let action = Action(choose)
                    actions.append(action)
                    // **`assumeIsolated` rather than a hop, and it is sound rather than convenient.** GTK
                    // dispatches this from `gtk_main`, which runs on the thread that called `gtk_init` --
                    // the main thread, because that is where this type may be used at all. Hopping instead
                    // would mean a menu item that acts one turn of the loop later, which for Quit is the
                    // difference between quitting and appearing not to.
                    facet_on(widget, "activate", { _, data in
                        guard let data else { return }
                        MainActor.assumeIsolated {
                            Unmanaged<Action>.fromOpaque(data).takeUnretainedValue().run()
                        }
                    }, Unmanaged.passUnretained(action).toOpaque())
                } else {
                    // A line that is telling you something rather than offering it. Insensitive so it does
                    // not read as a control that does nothing when pressed.
                    gtk_widget_set_sensitive(widget, 0)
                }
            }
            gtk_widget_show(widget)
            facet_menu_append(menu, widget)
            shown.append(widget)
        }
    }

    /// Draws the item and its menu again now, rather than waiting for the next tick.
    ///
    /// **What it is for is the states the tick does not cover promptly enough.** A second is right for a running
    /// clock and too slow for a cube connecting, a pairing being written or a link dropping -- each of which
    /// changes both the line and what is in the menu, and none of which has anything else about to redraw it.
    func redraw() {
        refreshLabel()
        rebuildIfChanged()
    }

    /// Puts the current reading beside the icon.
    ///
    /// **The guide is the widest the line gets**, which is what stops the panel shuffling as the digits change.
    /// A literal rather than the current text: `app_indicator_set_label` sizes to it, so a guide that tracked the
    /// answer would be no guide at all.
    private func refreshLabel() {
        app_indicator_set_label(indicator, Self.line(readout.read().title), "Category name 0:00:00")
    }

    /// One `StatusItemTitle` as a panel label.
    ///
    /// **Rendering, and every decision in it was made elsewhere.** The words, whether there is a figure at all,
    /// whether the seconds are in it and whether the line says `Connecting…` are `StatusItemTitle`'s; what is
    /// decided here is that a category's icon is not drawn at all, an `AppIndicator` label being text. Which
    /// character stands in for a Mac's SF Symbol is `SymbolGlyph`'s, the Faces tab drawing the same three.
    static func line(_ title: StatusItemTitle) -> String {
        [
            // A padlock, drawn in red on a Mac and plain here.
            SymbolGlyph.character(for: title.lockGlyphName),
            SymbolGlyph.character(for: title.glyphName),
            title.text,
            title.duration,
        ]
        .compactMap { $0 }
        .joined(separator: " ")
    }


    /// Hands the menu to the indicator and does not return: `gtk_main` is the run loop from here.
    func run() -> Never {
        rebuildIfChanged()
        refreshLabel()
        facet_indicator_set_menu(indicator, menu)

        // **A second, because it is a clock.** This is the one place a value is re-read on a timer rather
        // than at a point of use, which `CLAUDE.md` names as a case that has to say so: the label shows a
        // running total, and there is no event to hang it on -- the seconds simply pass. The read itself
        // still goes to the database every time; what the timer decides is only how often to ask.
        //
        // **Through the port rather than through `g_timeout_add_seconds` directly**, which is what this line
        // used to be. Nothing about the tick changed -- `GLibScheduler` arranges the same GLib source -- but
        // the last place in this target that reached for a clock of its own is gone, and the wake is now the
        // same call the six core modules make. `mayGroup` is deliberately not given: a figure showing seconds
        // that settles alongside some other wake is a figure that visibly skips one.
        repaint = scheduler.wake(in: 1, repeating: true) { [weak self] in
            self?.redraw()
        }

        debugLog?.record(.launch, "The menu bar item is up")
        gtk_main()
        // `gtk_main` returns when `gtk_main_quit` is called, and what follows a quit is exiting.
        exit(EXIT_SUCCESS)
    }

    /// Stops the run loop, which lets `run` return and the process end.
    static func quit() {
        gtk_main_quit()
    }
}
