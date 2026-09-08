import CGtk
import FacetCore
import Foundation

/// The status item, on the desktop's notification area.
///
/// **The Linux half of `MenuBarController`**, and the same shape as far as it goes: an icon that sits in
/// the bar, a label beside it, and a menu that opens on it. What draws it is an `AppIndicator`, which is
/// the tray protocol every desktop here understands -- MATE through `xapp-sn-watcher`, and anything else
/// implementing `org.kde.StatusNotifierWatcher`.
///
/// **Not in the accessibility tree, and that is measured rather than assumed** (2026-09-08, on the Linux
/// box): an application node has its windows as children and never its indicator, exactly as the macOS
/// status item is absent from `AXMenuBar`. A scripted check reaches this over D-Bus instead --
/// `com.canonical.dbusmenu`'s `GetLayout` reads the items and `Event` chooses one. See
/// `docs/linux-port.md`.
///
/// **Held for the life of the process.** The indicator is a GObject owned by GTK, but the menu items'
/// handlers are Swift closures reached through a `gpointer`, so this object being deallocated while the
/// bar still shows it would leave the callbacks pointing at freed memory.
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
        let run: @MainActor () -> Void
        init(_ run: @escaping @MainActor () -> Void) { self.run = run }
    }

    private let indicator: UnsafeMutablePointer<AppIndicator>
    private let menu: UnsafeMutablePointer<GtkWidget>
    /// Kept so the boxes outlive the menu. Nothing reads it; letting it go is what would be wrong.
    private var actions: [Action] = []
    private let debugLog: DebugLog?

    init(debugLog: DebugLog?) {
        self.debugLog = debugLog

        // `nil, nil` rather than the real argv: GTK's own switches are not this app's, and passing them
        // through would let `--display` reach it from a command line meant for something else.
        gtk_init(nil, nil)

        menu = gtk_menu_new()
        // **`indicator-messages` is a stock icon name, and deliberately a placeholder.** The app's own
        // icon is an `.icns` and this platform wants a themed name or a file path; which it becomes is
        // part of item 11 finishing, not of the bar appearing.
        indicator = app_indicator_new("facet", "indicator-messages",
                                      APP_INDICATOR_CATEGORY_APPLICATION_STATUS)
        app_indicator_set_status(indicator, APP_INDICATOR_STATUS_ACTIVE)
    }

    /// Adds an item to the bottom of the menu.
    ///
    /// **Shown as it is added.** A `GtkMenuItem` is hidden until told otherwise, and a menu whose items
    /// were never shown opens as an empty rectangle -- which looks like the menu failing to build rather
    /// than like items that are merely invisible.
    func add(_ title: String, _ run: @escaping @MainActor () -> Void) {
        let item = gtk_menu_item_new_with_label(title)
        let action = Action(run)
        actions.append(action)
        // **`assumeIsolated` rather than a hop, and it is sound rather than convenient.** GTK dispatches
        // this from `gtk_main`, which runs on the thread that called `gtk_init` -- the main thread, because
        // that is where this type may be used at all. Hopping instead would mean a menu item that acts one
        // turn of the loop later, which for Quit is the difference between quitting and appearing not to.
        facet_on_activate(item, { _, data in
            guard let data else { return }
            MainActor.assumeIsolated {
                Unmanaged<Action>.fromOpaque(data).takeUnretainedValue().run()
            }
        }, Unmanaged.passUnretained(action).toOpaque())
        gtk_widget_show(item)
        facet_menu_append(menu, item)
    }

    /// The text beside the icon, which is what `StatusItemTitle` produces on the other platform.
    ///
    /// The second argument is a **guide**: the widest string the label is expected to reach, so the panel
    /// can reserve room and the bar does not jump every time the figure changes width.
    func setLabel(_ text: String, guide: String) {
        app_indicator_set_label(indicator, text, guide)
    }

    /// Hands the menu to the indicator and does not return: `gtk_main` is the run loop from here.
    ///
    /// **The menu is set last, once its items exist.** An indicator handed an empty menu shows one, and
    /// adding to it afterwards is a second thing that has to work rather than the same thing done in order.
    func run() -> Never {
        facet_indicator_set_menu(indicator, menu)
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
