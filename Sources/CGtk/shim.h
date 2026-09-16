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

/* The handler takes the widget and a user-data pointer, which is `g_signal_connect`'s own shape. Returning
   the handler id rather than void so a caller could disconnect; nothing does yet, and a signal that cannot
   be unhooked is a thing to regret later rather than now.

   **The signal is a parameter rather than one wrapper per signal**, because a great many of GTK's carry
   exactly this handler: a menu item's `activate`, a button's `clicked`, a check box's `toggled`, a spin
   button's `value-changed`, an entry's `activate`, an expander's `activate`. Naming each of them here would
   be six identical functions, and the next widget would be a seventh. The signals whose handler is a
   *different* shape get their own wrapper below, which is the honest split: what varies is the signature,
   and that is what the C has to spell out. */
static inline gulong facet_on(GtkWidget *widget,
                              const char *signal,
                              void (*handler)(GtkWidget *, gpointer),
                              gpointer data) {
    return g_signal_connect(widget, signal, G_CALLBACK(handler), data);
}

/* The event signals: `key-press-event`, `focus-out-event`, `button-press-event`, `delete-event`. Their
   handler takes the event as well and answers whether it has been dealt with -- TRUE stopping GTK from
   passing it on -- so it cannot share `facet_on` above however similar it looks. */
static inline gulong facet_on_event(GtkWidget *widget,
                                    const char *signal,
                                    gboolean (*handler)(GtkWidget *, GdkEvent *, gpointer),
                                    gpointer data) {
    return g_signal_connect(widget, signal, G_CALLBACK(handler), data);
}

/* `GtkNotebook::switch-page`, whose handler is handed the page and its number. Its own wrapper for the
   reason the event one is: a third signature, spelled out where the compiler can check it. */
static inline gulong facet_on_switch_page(GtkWidget *notebook,
                                          void (*handler)(GtkWidget *, GtkWidget *, guint, gpointer),
                                          gpointer data) {
    return g_signal_connect(notebook, "switch-page", G_CALLBACK(handler), data);
}

/* **There is no wrapper for the menu being opened, and that is measured rather than an omission.**

   One belonged here: rebuilding the items at the moment somebody looks at them is what the macOS side does
   through `NSMenuDelegate.menuNeedsUpdate`, and it is `CLAUDE.md`'s first rule applied to a menu. It was
   `g_signal_connect(menu, "show", ...)` until 2026-09-13, and it never fired once.

   Measured on the Linux box with a two-item probe indicator: a panel opening the menu calls
   `com.canonical.dbusmenu`'s `AboutToShow`, which returns FALSE and reaches no signal on the `GtkMenu` at
   all, and the single `show` such a menu ever emits is emitted by `app_indicator_set_menu` itself. The
   `DbusmenuServer` that would have to forward it belongs to libayatana-appindicator and is not handed out,
   so there is nothing to hook. `MenuBar` re-reads the menu on its own tick instead and says so. */

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

/* **The Settings window's casts, and there are a lot of them for one reason: every one is a macro.**

   `GTK_CONTAINER(x)`, `GTK_BOX(x)`, `GTK_WINDOW(x)` and the rest are `g_type_check_instance_cast` behind a
   macro, which the Swift importer leaves behind exactly as it leaves `GTK_MENU_SHELL` behind. The choice at
   every call is the same one this file already made twice: reimplement the cast with `unsafeBitCast` and
   throw away the type check the macro exists to perform, or write the cast here in C where it works. Doing
   it here also means a wrong widget is caught by GTK's own warning naming both types, rather than by
   whatever the mis-cast pointer does next.

   These are ordered by widget, not by the window that uses them: what belongs in this file is the C, and
   which pane reaches for which is `FacetLinux`'s business. */

static inline void facet_container_add(GtkWidget *container, GtkWidget *child) {
    gtk_container_add(GTK_CONTAINER(container), child);
}

/* What a container currently holds, for a list that rebuilds itself: the widgets have to be destroyed, and
   GTK's own answer to "what is in here" is a `GList` the caller frees. */
static inline GList *facet_container_children(GtkWidget *container) {
    return gtk_container_get_children(GTK_CONTAINER(container));
}

/* A widget drawn on top of another, which is how a category's icon sits on its colour: the swatch is a
   drawing area and the icon is an image, and neither has to know about the other. `gtk_overlay_add_overlay`
   takes the container rather than the overlay, so it is a cast like the rest. */
static inline void facet_overlay_add(GtkWidget *overlay, GtkWidget *child) {
    gtk_overlay_add_overlay(GTK_OVERLAY(overlay), child);
}

static inline void facet_container_remove(GtkWidget *container, GtkWidget *child) {
    gtk_container_remove(GTK_CONTAINER(container), child);
}

/* `expand` and `fill` are the two halves of what a box does with the room a child does not want: whether the
   child is given a share of the spare space, and whether it grows into the share it was given. Both are
   passed through rather than fixed here, a row of columns and a pane of sections wanting opposite answers. */
static inline void facet_box_pack_start(GtkWidget *box, GtkWidget *child,
                                        gboolean expand, gboolean fill, guint padding) {
    gtk_box_pack_start(GTK_BOX(box), child, expand, fill, padding);
}

static inline void facet_box_pack_end(GtkWidget *box, GtkWidget *child,
                                      gboolean expand, gboolean fill, guint padding) {
    gtk_box_pack_end(GTK_BOX(box), child, expand, fill, padding);
}

static inline void facet_window_set_title(GtkWidget *window, const char *title) {
    gtk_window_set_title(GTK_WINDOW(window), title);
}

static inline void facet_window_set_default_size(GtkWidget *window, int width, int height) {
    gtk_window_set_default_size(GTK_WINDOW(window), width, height);
}

/* **One width and a free height**, which is `CLAUDE.md`'s *A tab's content spans the width of the window*
   made true by the window manager rather than asked of it: the minimum and the maximum width are the same
   number, and the height's maximum is `G_MAXINT`. `GdkGeometry` is a plain struct Swift can fill in, so the
   only thing needing C here is the `GTK_WINDOW` cast -- but the hint flags belong next to the struct they
   describe, and getting them wrong pins the wrong axis, so the whole call is one wrapper. */
static inline void facet_window_pin_width(GtkWidget *window, int width, int minimumHeight) {
    GdkGeometry geometry;
    geometry.min_width = width;
    geometry.max_width = width;
    geometry.min_height = minimumHeight;
    geometry.max_height = G_MAXINT;
    gtk_window_set_geometry_hints(GTK_WINDOW(window), NULL, &geometry,
                                  (GdkWindowHints)(GDK_HINT_MIN_SIZE | GDK_HINT_MAX_SIZE));
}

static inline void facet_notebook_append_page(GtkWidget *notebook, GtkWidget *page, GtkWidget *label) {
    gtk_notebook_append_page(GTK_NOTEBOOK(notebook), page, label);
}

static inline void facet_notebook_set_current_page(GtkWidget *notebook, int page) {
    gtk_notebook_set_current_page(GTK_NOTEBOOK(notebook), page);
}

static inline int facet_notebook_get_current_page(GtkWidget *notebook) {
    return gtk_notebook_get_current_page(GTK_NOTEBOOK(notebook));
}

static inline gboolean facet_toggle_get_active(GtkWidget *toggle) {
    return gtk_toggle_button_get_active(GTK_TOGGLE_BUTTON(toggle));
}

static inline void facet_toggle_set_active(GtkWidget *toggle, gboolean active) {
    gtk_toggle_button_set_active(GTK_TOGGLE_BUTTON(toggle), active);
}

/* The text as GTK holds it, which is borrowed rather than owned: it belongs to the entry and is good until
   the entry is next written to. Swift copies it into a `String` at the call site, which is the only thing a
   caller here ever does with it. */
static inline const char *facet_entry_get_text(GtkWidget *entry) {
    return gtk_entry_get_text(GTK_ENTRY(entry));
}

static inline void facet_entry_set_text(GtkWidget *entry, const char *text) {
    gtk_entry_set_text(GTK_ENTRY(entry), text);
}

static inline void facet_entry_set_placeholder(GtkWidget *entry, const char *text) {
    gtk_entry_set_placeholder_text(GTK_ENTRY(entry), text);
}

/* In characters, and `-1` for no limit. What it is for is the same thing `EditableNameCell.maximumLength`
   is for on the Mac: a length is the one limit a field can hold honestly, because what is on screen is then
   what will be written. */
static inline void facet_entry_set_max_length(GtkWidget *entry, int length) {
    gtk_entry_set_max_length(GTK_ENTRY(entry), length);
}

/* Selects the whole name, so typing replaces it. `0, -1` is from the first character to the last. */
static inline void facet_entry_select_all(GtkWidget *entry) {
    gtk_editable_select_region(GTK_EDITABLE(entry), 0, -1);
}

static inline int facet_spin_get_value_as_int(GtkWidget *spin) {
    return gtk_spin_button_get_value_as_int(GTK_SPIN_BUTTON(spin));
}

static inline void facet_spin_set_value(GtkWidget *spin, double value) {
    gtk_spin_button_set_value(GTK_SPIN_BUTTON(spin), value);
}

static inline void facet_expander_set_expanded(GtkWidget *expander, gboolean expanded) {
    gtk_expander_set_expanded(GTK_EXPANDER(expander), expanded);
}

static inline gboolean facet_expander_get_expanded(GtkWidget *expander) {
    return gtk_expander_get_expanded(GTK_EXPANDER(expander));
}

/* **A widget as the heading rather than a string, which is what makes the whole line the target.**
   `CLAUDE.md` requires that a collapsible group opens on its heading and not only on its triangle, and an
   expander's title row is what GTK gives a click: `label_fill` makes the label widget span that row, so the
   words and the space after them to the end of the line are inside it. The Mac gets the same result by
   putting a borderless button behind the triangle and the label. */
static inline void facet_expander_set_label_widget(GtkWidget *expander, GtkWidget *label) {
    gtk_expander_set_label_widget(GTK_EXPANDER(expander), label);
    gtk_expander_set_label_fill(GTK_EXPANDER(expander), TRUE);
}

/* A heading's weight, which GTK has no label property for: bold is markup, and markup is XML, which is why
   `PanelSection` escapes a title before it gets here. */
static inline void facet_label_set_markup(GtkWidget *label, const char *markup) {
    gtk_label_set_markup(GTK_LABEL(label), markup);
}

/* A name too long for its column ends in an ellipsis rather than widening the row: the window is one width,
   so something has to give, and a truncated name in a column that stays put reads better than a table that
   shifts from row to row. */
/* A name too long for one line wraps, and is truncated only past `lines`. The Mac's `nameMaximumLines`,
   and its reasoning: the second line is used when it is needed rather than reserved, so nothing below the
   name moves for a one-word category. */
static inline void facet_label_wrap_lines(GtkWidget *label, int lines) {
    gtk_label_set_line_wrap(GTK_LABEL(label), TRUE);
    gtk_label_set_lines(GTK_LABEL(label), lines);
    gtk_label_set_ellipsize(GTK_LABEL(label), PANGO_ELLIPSIZE_END);
    gtk_label_set_justify(GTK_LABEL(label), GTK_JUSTIFY_CENTER);
}

static inline void facet_label_ellipsize_end(GtkWidget *label) {
    gtk_label_set_ellipsize(GTK_LABEL(label), PANGO_ELLIPSIZE_END);
}

/* No frame and no relief, which is what makes an icon or a swatch clickable without reading as a control in
   a column of readings. The Mac's equivalent is `isBordered = false`. */
static inline void facet_button_flatten(GtkWidget *button) {
    gtk_button_set_relief(GTK_BUTTON(button), GTK_RELIEF_NONE);
}

/* Which widget the keyboard is pointing at, and whether it is a field.

   **What this is for is Escape.** The Mac has to lend its Close button's key equivalent to whichever field is
   open, because a key equivalent is dispatched before the focused field ever sees the key. GTK has the same
   ordering -- a toplevel's `key-press-event` handler runs before the focus widget's -- so the window asks
   what has focus instead of keeping track of who is editing: an entry is abandoning an edit, and anything
   else is closing the window. Two calls rather than one because `GTK_IS_ENTRY` is a macro too. */
static inline gboolean facet_is_entry_focused(GtkWidget *window) {
    GtkWidget *focus = gtk_window_get_focus(GTK_WINDOW(window));
    return focus != NULL && GTK_IS_ENTRY(focus);
}

/* Brings a window that is already up to the front, rather than building a second one: two Settings windows
   would be two answers to every setting in them. */
static inline void facet_window_present(GtkWidget *window) {
    gtk_window_present(GTK_WINDOW(window));
}

/* A picker hanging off the cell that opened it, which is what an `NSPopover` is on the Mac and for the same
   reason: the grid belongs to the row it was opened from, where a window would have to say which category it
   was for. */
static inline void facet_popover_popup(GtkWidget *popover) {
    gtk_popover_popup(GTK_POPOVER(popover));
}

static inline void facet_popover_popdown(GtkWidget *popover) {
    gtk_popover_popdown(GTK_POPOVER(popover));
}

/* **The name a check finds a control by**, which is not the name CSS uses.

   `gtk_widget_set_name` sets the widget's name, which styles it and reaches nothing outside the process.
   What AT-SPI answers with is the *accessible* name, which is ATK's -- measured on this box 2026-09-08 and
   written up in `docs/linux-port.md`: a locator is one tree walk comparing `name`, and that name comes from
   here. Both are set together at every call site, so an identifier is one string rather than two that can
   drift, exactly as `AXIdentifier` and `NSUserInterfaceItemIdentifier` are set together on the Mac.

   A widget with no accessible object -- which is possible, ATK creating them lazily -- is left alone rather
   than crashed on. */
static inline void facet_set_accessible_name(GtkWidget *widget, const char *name) {
    AtkObject *accessible = gtk_widget_get_accessible(widget);
    if (accessible != NULL) {
        atk_object_set_name(accessible, name);
    }
}

/* **What a control says, where its own text is a value the app wrote.**

   A `GtkButton` reports its label as its accessible *name*, and this window puts the identifier there
   instead -- so the name a category is called, which is the button's whole content, would be readable
   nowhere. The Mac keeps the two apart for free, `AXIdentifier` and `AXValue` being different attributes;
   here the second one is the description. Measured 2026-09-16: with only the name set, a category name cell
   came back as `push button 'category-name-1' ''` with no text interface and no child label. */
static inline void facet_set_accessible_description(GtkWidget *widget, const char *description) {
    AtkObject *accessible = gtk_widget_get_accessible(widget);
    if (accessible != NULL) {
        atk_object_set_description(accessible, description);
    }
}

/* Where a label sits in the room it has been given: 0 is the leading edge, 1 the trailing one. A caption
   over a column has to start where the column does, and a label left to centre itself does not. */
static inline void facet_label_set_xalign(GtkWidget *label, float alignment) {
    gtk_label_set_xalign(GTK_LABEL(label), alignment);
}

/* **The app's own stylesheet, loaded once for the whole screen.** GTK's answer to a tint or a corner radius
   is CSS on a named class, which is why the panel a section draws is a style rule rather than a drawing
   routine the way `ColourSwatch` is on the Mac. Answers the error rather than swallowing it: a stylesheet
   that failed to parse leaves every panel untinted, which is exactly the kind of thing that gets noticed
   months later as "the window looks wrong". */
static inline char *facet_style_add(const char *css) {
    GtkCssProvider *provider = gtk_css_provider_new();
    GError *error = NULL;
    gtk_css_provider_load_from_data(provider, css, -1, &error);
    if (error != NULL) {
        char *message = g_strdup(error->message);
        g_error_free(error);
        g_object_unref(provider);
        return message;
    }
    gtk_style_context_add_provider_for_screen(gdk_screen_get_default(),
                                              GTK_STYLE_PROVIDER(provider),
                                              GTK_STYLE_PROVIDER_PRIORITY_APPLICATION);
    g_object_unref(provider);
    return NULL;
}

/* A category's colour as a filled square, and the absence of one as a hollow outline -- the same
   distinction `ColourSwatch` draws on the Mac, and for its reason: grey is a colour in the palette
   (`database/005_colour.sql`), so filling with grey would say somebody chose grey.

   **Drawn rather than styled**, which is the one place this window departs from CSS: the colour comes out
   of the `colour` table per row, and a stylesheet would mean a generated class name per palette entry. */
static inline void facet_draw_swatch(cairo_t *cr, double size, double radius,
                                     double red, double green, double blue, gboolean filled) {
    double edge = 0.5;
    double right = size - edge;
    double bottom = size - edge;
    cairo_new_sub_path(cr);
    cairo_arc(cr, right - radius, edge + radius, radius, -G_PI / 2, 0);
    cairo_arc(cr, right - radius, bottom - radius, radius, 0, G_PI / 2);
    cairo_arc(cr, edge + radius, bottom - radius, radius, G_PI / 2, G_PI);
    cairo_arc(cr, edge + radius, edge + radius, radius, G_PI, 3 * G_PI / 2);
    cairo_close_path(cr);
    if (filled) {
        cairo_set_source_rgb(cr, red, green, blue);
        cairo_fill_preserve(cr);
        /* A faint outline, so a swatch the same colour as the panel behind it still reads as a square. */
        cairo_set_source_rgba(cr, 0.5, 0.5, 0.5, 0.4);
    } else {
        cairo_set_source_rgba(cr, red, green, blue, 0.8);
    }
    cairo_set_line_width(cr, 1);
    cairo_stroke(cr);
}

/* `GtkWidget::draw`, whose handler is handed a cairo context. A fourth signature, and the last one. */
static inline gulong facet_on_draw(GtkWidget *widget,
                                   gboolean (*handler)(GtkWidget *, cairo_t *, gpointer),
                                   gpointer data) {
    return g_signal_connect(widget, "draw", G_CALLBACK(handler), data);
}
