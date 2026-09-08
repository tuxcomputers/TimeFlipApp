/* GTK3 and the Ayatana app indicator, for Swift.

   Included by name rather than by path: `pkgConfig: "ayatana-appindicator3-0.1"` in Package.swift is what
   supplies the include directories, and there are several -- GTK alone spreads across /usr/include/gtk-3.0,
   /usr/include/glib-2.0 and the arch-dependent /usr/lib/<triple>/glib-2.0/include. Asking pkg-config is the
   same reasoning as CDBus, where the arch-dependent `dbus-arch-deps.h` sits apart from the rest.

   The appindicator header pulls GTK in itself, but GTK is included first and explicitly: this file is read
   by somebody working out what the module contains, and a header that arrives as a side effect of another
   one is a dependency nobody can see. */
#include <gtk/gtk.h>
#include <libayatana-appindicator/app-indicator.h>

/* **The three things below are macros in GTK, and Swift cannot see a macro.**

   `GTK_MENU_SHELL(x)` and `GTK_MENU(x)` are checked casts, and `g_signal_connect(...)` is a wrapper over
   `g_signal_connect_data`. Swift's C importer brings functions across and leaves macros behind, so calling
   these from Swift means either reimplementing the cast with `unsafeBitCast` -- which throws away the type
   check the macro exists to perform -- or doing it here, in C, where the macro works.

   Doing it here is the same choice `CDBus` made for a different reason: libdbus's append API is variadic
   and so uncallable from Swift, and the iterator API was used instead. A macro is the other half of that
   coin. Both are C being C, and both are best answered in one small file rather than at every call site. */

static inline void facet_menu_append(GtkWidget *menu, GtkWidget *item) {
    gtk_menu_shell_append(GTK_MENU_SHELL(menu), item);
}

static inline void facet_indicator_set_menu(AppIndicator *indicator, GtkWidget *menu) {
    app_indicator_set_menu(indicator, GTK_MENU(menu));
}

/* The handler takes the item and a user-data pointer, which is `g_signal_connect`'s own shape. Returning
   the handler id rather than void so a caller could disconnect; nothing does yet, and a signal that cannot
   be unhooked is a thing to regret later rather than now. */
static inline gulong facet_on_activate(GtkWidget *item,
                                       void (*handler)(GtkWidget *, gpointer),
                                       gpointer data) {
    return g_signal_connect(item, "activate", G_CALLBACK(handler), data);
}

/* The menu being opened. What it is for is rebuilding the items at the moment somebody looks at them,
   rather than on a timer that would be rewriting a menu while it is on screen -- which is `CLAUDE.md`'s
   first rule applied to a menu: the totals are read when they are wanted, not held and refreshed. */
static inline gulong facet_on_show(GtkWidget *menu,
                                   void (*handler)(GtkWidget *, gpointer),
                                   gpointer data) {
    return g_signal_connect(menu, "show", G_CALLBACK(handler), data);
}
