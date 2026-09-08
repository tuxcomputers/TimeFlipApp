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
/// `docs/linux-port.md`.
///
/// **Nothing here holds what it shows.** The label is asked for on every tick and the menu is rebuilt when
/// somebody opens it, both from closures that go to the database -- which is `CLAUDE.md`'s first rule, and
/// the reason the menu cannot come to disagree with the Faces tab about what is being timed.
///
/// **`@MainActor`, and GTK is the reason rather than the compiler.** GTK3 is not thread-safe: every call
/// has to come from the thread that called `gtk_init`, and `gtk_main` runs its loop on that same thread.
/// So the isolation is not an accommodation made to satisfy `DebugLog` -- it is what was already true,
/// written down where the compiler can hold us to it.
@MainActor
final class MenuBar {
    /// One line of the menu: what it says, and what choosing it does. `nil` for a line that is only telling
    /// you something, which comes out insensitive rather than as a control that looks live and is not.
    struct Item {
        let title: String
        let choose: (@MainActor () -> Void)?

        init(_ title: String, choose: (@MainActor () -> Void)? = nil) {
            self.title = title
            self.choose = choose
        }

        /// A dividing line. GTK draws it from its own widget, so the title is never read.
        static let separator = Item("")
        var isSeparator: Bool { title.isEmpty && choose == nil }
    }

    /// What a menu item does when it is chosen. Boxed into a class so it survives as an
    /// `Unmanaged` pointer across the C boundary, which cannot carry a Swift closure directly.
    private final class Action {
        let run: @MainActor () -> Void
        init(_ run: @escaping @MainActor () -> Void) { self.run = run }
    }

    private let indicator: UnsafeMutablePointer<AppIndicator>
    private let menu: UnsafeMutablePointer<GtkWidget>
    private let debugLog: DebugLog?

    /// Asked every second for what the label should say, and asked again as the menu opens for what should
    /// be in it. Closures rather than values, so this type reads and never remembers.
    private let label: @MainActor () -> (text: String, guide: String)
    private let items: @MainActor () -> [Item]

    /// The widgets and boxes making up the menu as it currently stands, destroyed and rebuilt together.
    /// **Not a copy of anything true** -- it is what GTK was handed, kept only so it can be taken back.
    private var shown: [UnsafeMutablePointer<GtkWidget>] = []
    private var actions: [Action] = []

    init(debugLog: DebugLog?,
         label: @escaping @MainActor () -> (text: String, guide: String),
         items: @escaping @MainActor () -> [Item]) {
        self.debugLog = debugLog
        self.label = label
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
        // without `FacetApp_FacetLinux.resources` next to it has no logo to show. That is the same trap the
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

    /// Throws away the menu as it stands and builds it again from `items()`.
    ///
    /// **Rebuilt rather than edited.** Working out which rows changed and patching them is how a menu comes
    /// to show a category that was retired ten seconds ago: the rows are cheap and the question "what
    /// should be here now" has one answer, which is what `items()` returns.
    private func rebuild() {
        for widget in shown { gtk_widget_destroy(widget) }
        shown.removeAll()
        actions.removeAll()

        for item in items() {
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
                    facet_on_activate(widget, { _, data in
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

    /// Puts the current reading beside the icon.
    private func refreshLabel() {
        let (text, guide) = label()
        app_indicator_set_label(indicator, text, guide)
    }

    /// Hands the menu to the indicator and does not return: `gtk_main` is the run loop from here.
    func run() -> Never {
        rebuild()
        refreshLabel()
        facet_indicator_set_menu(indicator, menu)

        // **Rebuilt as it opens, which is when somebody is about to read it.** The alternative is a timer
        // rewriting a menu that may be on screen, and a total that was right when the timer last fired is
        // exactly the second copy `CLAUDE.md` forbids.
        facet_on_show(menu, { _, data in
            guard let data else { return }
            MainActor.assumeIsolated {
                Unmanaged<MenuBar>.fromOpaque(data).takeUnretainedValue().rebuild()
            }
        }, Unmanaged.passUnretained(self).toOpaque())

        // **A second, because it is a clock.** This is the one place a value is re-read on a timer rather
        // than at a point of use, which `CLAUDE.md` names as a case that has to say so: the label shows a
        // running total, and there is no event to hang it on -- the seconds simply pass. The read itself
        // still goes to the database every time; what the timer decides is only how often to ask.
        g_timeout_add_seconds(1, { data in
            guard let data else { return 0 }
            MainActor.assumeIsolated {
                Unmanaged<MenuBar>.fromOpaque(data).takeUnretainedValue().refreshLabel()
            }
            return 1  // G_SOURCE_CONTINUE
        }, Unmanaged.passUnretained(self).toOpaque())

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
