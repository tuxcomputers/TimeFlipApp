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

/* **The dialogue square's GTK slot needs four wrappers, and two of them are the variadic problem again.**

   `gtk_message_dialog_new` and `gtk_message_dialog_format_secondary_text` both take a printf format and a
   variable argument list, which Swift's importer cannot call at all -- the same wall `CDBus` met with
   `dbus_message_append_args` and libsecret's simple API. Here the answer is smaller than either of those:
   the app never wants a format, it wants one string, so `"%s"` is passed in C and the string travels as an
   argument rather than as a format. That also happens to be the only safe way to do it: a heading containing
   a `%` would otherwise be read as a conversion.

   The other two are the `GTK_DIALOG(x)` checked cast, which is a macro for the reason the two above this
   file already are. */

static inline GtkWidget *facet_message_dialog_new(int is_warning, const char *heading, const char *body) {
    GtkWidget *dialog = gtk_message_dialog_new(
        NULL,
        GTK_DIALOG_MODAL,
        is_warning ? GTK_MESSAGE_WARNING : GTK_MESSAGE_INFO,
        /* No buttons of its own: every one of them is `Dialogue.choices`, added in order so the response id
           is the position in that list and no platform numbering ever reaches the core. */
        GTK_BUTTONS_NONE,
        "%s", heading);
    gtk_message_dialog_format_secondary_text(GTK_MESSAGE_DIALOG(dialog), "%s", body);
    return dialog;
}

static inline void facet_dialog_add_button(GtkWidget *dialog, const char *title, int response) {
    gtk_dialog_add_button(GTK_DIALOG(dialog), title, response);
}

/* Return lands here. GTK does not relocate a button by its title the way AppKit does, so `Dialogue.wayOut`
   is simply honoured rather than worked around. */
static inline void facet_dialog_set_default(GtkWidget *dialog, int response) {
    gtk_dialog_set_default_response(GTK_DIALOG(dialog), response);
}

/* Runs a nested main loop until something is chosen, which is what `NSAlert.runModal` does on the other
   platform and for the same reason: somebody who starts the app and walks away has to find the question where
   they left it. The app's own wakes are on the same main context, so its clock goes on ticking inside it. */
static inline int facet_dialog_run(GtkWidget *dialog) {
    return gtk_dialog_run(GTK_DIALOG(dialog));
}
