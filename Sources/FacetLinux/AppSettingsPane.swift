import CGtk
import FacetCore
import Foundation

/// The App tab: the app's own preferences, and the debug trace.
///
/// **Two sections where the Mac has three.** Its Google section is not built here yet -- the listener the sign-in
/// needs is still a port with two implementations behind one conditional, which is item 16 of `docs/linux-port.md`
/// and is the Mac's half to do. Drawing a Connect button that cannot connect would be the control that looks live
/// and does nothing, which this app refuses everywhere else, so there is no section rather than a dead one.
///
/// **Every row is written straight through and read back**, which is `CLAUDE.md`'s licence for an open Settings
/// window: the window holds what it read when it opened, a changed field is written through `AppSettingWrite`, and
/// the row is put back with an alert if the table refuses it. What is decided about a change -- which setting, which
/// field, which type, and the conversion between what a control offers and what the row holds -- is
/// `AppSettingsRules`', in the core, for both platforms.
///
/// **The values are read once, on open.** That is the one place this app holds a setting rather than re-reading it,
/// and the conditions are the rule's own: every tab's settings in one go, written through, read back, and given up
/// when the window closes. Here the window is destroyed on close, so giving up happens by itself.
@MainActor
final class AppSettingsPane {
    let widget: UnsafeMutablePointer<GtkWidget>

    private let settings: SettingStore
    private let debugLog: DebugLog?
    private let dialogues: DialoguePresenter
    private let timingChanged: () -> Void

    private let preferences: UnsafeMutablePointer<GtkWidget>
    private let debugRows: UnsafeMutablePointer<GtkWidget>
    private var signals = GtkSignals()

    /// What the table said when the window opened, and what the rows are drawn from.
    ///
    /// **The one held copy in this window**, under the conditions `CLAUDE.md` sets for one: read in a single pass on
    /// open, updated only after a write has been read back, and gone when the window closes. A value the table gains
    /// meanwhile is overwritten, which is the rule's fourth condition -- this window read the setting when it opened
    /// and has been the answer since.
    private var values = Values.seeded

    /// What the App tab shows, in one struct, so opening the window is one pass over the table rather than a read
    /// per control.
    struct Values: Equatable {
        var showsSeconds: Bool
        var dailyResetHour24: Int
        var fetchIntervalSeconds: Int
        var blipSeconds: Int
        var isDebugEnabled: Bool
        var debugDirectory: String
        /// Whether there is a trace file to act on. **Not a setting, and not `isDebugEnabled`**: the file outlives
        /// both the launch that wrote it and logging being on, which is most of a support conversation -- somebody
        /// turns logging on, reproduces the fault, quits, and sends the file from a launch that is recording
        /// nothing.
        var hasDebugTrace: Bool

        /// What a database with none of these rows would give, which is what the seeds give
        /// (`database/011_setting.sql`).
        static let seeded = Values(
            showsSeconds: AppSettingsRules.defaultShowsSeconds,
            dailyResetHour24: AppSettingsRules.defaultResetHour24,
            fetchIntervalSeconds: AppSettingsRules.defaultFetchIntervalSeconds,
            blipSeconds: AppSettingsRules.defaultBlipSeconds,
            isDebugEnabled: DebugTraceRules.defaultEnabled,
            debugDirectory: DebugTraceRules.defaultDirectory,
            hasDebugTrace: false
        )
    }

    init(
        settings: SettingStore,
        dialogues: DialoguePresenter,
        debugLog: DebugLog?,
        timingChanged: @escaping () -> Void
    ) {
        self.settings = settings
        self.dialogues = dialogues
        self.debugLog = debugLog
        self.timingChanged = timingChanged

        widget = SettingsWidgets.column(spacing: Int(SettingsMetrics.sectionSpacing))
        SettingsWidgets.identify(widget, SettingsTab.app.paneIdentifier)
        for margin in [gtk_widget_set_margin_top, gtk_widget_set_margin_bottom,
                       gtk_widget_set_margin_start, gtk_widget_set_margin_end] {
            margin(widget, Int32(SettingsMetrics.tabPadding))
        }
        preferences = SettingsWidgets.column()
        debugRows = SettingsWidgets.column()

        let preferencesSection = PanelSection(
            title: "App settings",
            identifier: "app-settings-section",
            isExpanded: true,
            content: preferences
        )
        let debugSection = PanelSection(
            title: "Debug",
            identifier: "app-debug-section",
            // **Closed, because it is not an everyday control.** The trace is a thing somebody is asked to turn on
            // during a support conversation, and it costs disk while it is on.
            isExpanded: false,
            content: debugRows
        )
        preferencesSection.onToggle = { [weak self] isExpanded in
            self?.debugLog?.record(.tab, "App section App settings \(isExpanded ? "opened" : "folded")")
        }
        debugSection.onToggle = { [weak self] isExpanded in
            self?.debugLog?.record(.tab, "App section Debug \(isExpanded ? "opened" : "folded")")
        }
        sections = [preferencesSection, debugSection]
        facet_box_pack_start(widget, preferencesSection.widget, 0, 1, 0)
        facet_box_pack_start(widget, debugSection.widget, 0, 1, 0)
    }

    /// Held because a `PanelSection` owns its own handlers, and GTK retains the widgets rather than the Swift object
    /// around them.
    private var sections: [PanelSection] = []

    /// Reads every value this tab shows, in one go, and draws them.
    ///
    /// **One pass rather than a read per control**, which is the rule's first condition for a window that may hold
    /// what it shows. Each row falls back to what a fresh database would have seeded, because `SettingStore` answers
    /// `nil` for a missing or malformed row and refuses to guess what absence means.
    func reload() {
        let seeded = Values.seeded
        values = Values(
            showsSeconds: settings.flag("display_seconds", field: "enabled") ?? seeded.showsSeconds,
            dailyResetHour24: settings.integer("daily_reset_time", field: "hour") ?? seeded.dailyResetHour24,
            fetchIntervalSeconds: settings.integer("fetch_history_interval_seconds", field: "seconds")
                ?? seeded.fetchIntervalSeconds,
            blipSeconds: settings.integer("blip_time", field: "seconds") ?? seeded.blipSeconds,
            isDebugEnabled: settings.flag(DebugTraceRules.setting, field: DebugTraceRules.enabledField)
                ?? seeded.isDebugEnabled,
            debugDirectory: settings.string(DebugTraceRules.setting, field: DebugTraceRules.directoryField)
                ?? seeded.debugDirectory,
            hasDebugTrace: DebugTraceFile.inUse(
                by: debugLog,
                directory: settings.string(DebugTraceRules.setting, field: DebugTraceRules.directoryField)
                    ?? seeded.debugDirectory
            ).exists
        )
        redraw()
    }

    private func redraw() {
        for child in SettingsWidgets.children(of: preferences) + SettingsWidgets.children(of: debugRows) {
            gtk_widget_destroy(child)
        }
        signals = GtkSignals()
        drawPreferences()
        drawDebug()
        gtk_widget_show_all(widget)
    }

    // MARK: - the preferences

    private func drawPreferences() {
        facet_box_pack_start(preferences, secondsRow(), 0, 1, 0)
        facet_box_pack_start(preferences, resetRow(), 0, 1, 0)
        facet_box_pack_start(preferences, fetchRow(), 0, 1, 0)
        facet_box_pack_start(preferences, blipRow(), 0, 1, 0)
    }

    private func secondsRow() -> UnsafeMutablePointer<GtkWidget> {
        let box = gtk_check_button_new_with_label("Show seconds in the menu bar")!
        SettingsWidgets.identify(box, "app-display-seconds")
        facet_toggle_set_active(box, values.showsSeconds ? 1 : 0)
        signals.connect(box, "toggled") { [weak self] in
            guard let self else { return }
            let wanted = facet_toggle_get_active(box) != 0
            guard wanted != values.showsSeconds else { return }
            apply(.showsSeconds(wanted)) { [weak self] in self?.values.showsSeconds = wanted }
        }
        return row("", control: box)
    }

    /// The hour the app's day turns over, on a clock face.
    ///
    /// **12 on the control and 24 in the row**, which is `AppSettingsRules`' conversion in both directions: the
    /// archive offered a clock-face hour, and the table holds what a comparison needs.
    private func resetRow() -> UnsafeMutablePointer<GtkWidget> {
        let field = gtk_spin_button_new_with_range(1, 12, 1)!
        SettingsWidgets.identify(field, "app-daily-reset")
        facet_spin_set_value(field, Double(AppSettingsRules.hour12(from: values.dailyResetHour24)))
        signals.connect(field, "value-changed") { [weak self] in
            guard let self else { return }
            let hour12 = Int(facet_spin_get_value_as_int(field))
            guard hour12 != AppSettingsRules.hour12(from: values.dailyResetHour24) else { return }
            apply(.dailyResetHour12(hour12)) { [weak self] in
                self?.values.dailyResetHour24 = AppSettingsRules.hour24(fromFace: hour12)
            }
        }
        return row("The day starts at", control: field, suffix: "am")
    }

    private func fetchRow() -> UnsafeMutablePointer<GtkWidget> {
        let minutes = AppSettingsRules.minutes(fromSeconds: values.fetchIntervalSeconds)
        let field = gtk_spin_button_new_with_range(1, 60, 1)!
        SettingsWidgets.identify(field, "app-fetch-interval")
        facet_spin_set_value(field, Double(minutes))
        signals.connect(field, "value-changed") { [weak self] in
            guard let self else { return }
            let wanted = Int(facet_spin_get_value_as_int(field))
            guard wanted != AppSettingsRules.minutes(fromSeconds: values.fetchIntervalSeconds) else { return }
            apply(.fetchIntervalMinutes(wanted)) { [weak self] in
                self?.values.fetchIntervalSeconds = AppSettingsRules.seconds(fromMinutes: wanted)
            }
        }
        return row("Ask the cube for its history every", control: field, suffix: "min")
    }

    private func blipRow() -> UnsafeMutablePointer<GtkWidget> {
        let field = gtk_spin_button_new_with_range(0, 60, 1)!
        SettingsWidgets.identify(field, "app-blip-time")
        facet_spin_set_value(field, Double(values.blipSeconds))
        signals.connect(field, "value-changed") { [weak self] in
            guard let self else { return }
            let wanted = Int(facet_spin_get_value_as_int(field))
            guard wanted != values.blipSeconds else { return }
            apply(.blipSeconds(wanted)) { [weak self] in self?.values.blipSeconds = wanted }
        }
        return row("Ignore turns shorter than", control: field, suffix: "sec")
    }

    // MARK: - the debug trace

    private func drawDebug() {
        let box = gtk_check_button_new_with_label("Record a debug trace")!
        SettingsWidgets.identify(box, "app-debug-enabled")
        facet_toggle_set_active(box, values.isDebugEnabled ? 1 : 0)
        signals.connect(box, "toggled") { [weak self] in
            guard let self else { return }
            let wanted = facet_toggle_get_active(box) != 0
            guard wanted != values.isDebugEnabled else { return }
            apply(.debugEnabled(wanted)) { [weak self] in
                guard let self else { return }
                values.isDebugEnabled = wanted
                // **Told here, and only here, and only now.** `DebugLog.isRecording` is a copy of this row held in
                // memory; what keeps it honest is that this is the single place it is set, and that it is set after
                // the write has been read back. A logger told before the table agreed would be recording on the
                // strength of a write that did not happen.
                debugLog?.setRecording(wanted)
                // Turning it on writes the first row, which brings the file into being -- and the buttons below are
                // drawn from whether there is a file.
                values.hasDebugTrace = DebugTraceFile.inUse(by: debugLog, directory: values.debugDirectory).exists
                redraw()
            }
        }
        facet_box_pack_start(debugRows, row("", control: box), 0, 1, 0)

        let directory = gtk_entry_new()!
        SettingsWidgets.identify(directory, "app-debug-directory")
        facet_entry_set_text(directory, values.debugDirectory)
        facet_entry_set_placeholder(directory, DebugTraceRules.defaultDirectory)
        signals.connect(directory, "activate") { [weak self] in
            guard let self else { return }
            let typed = String(cString: facet_entry_get_text(directory))
            guard typed != values.debugDirectory else { return }
            apply(.debugDirectory(typed)) { [weak self] in
                guard let self else { return }
                values.debugDirectory = typed
                values.hasDebugTrace = DebugTraceFile.inUse(by: debugLog, directory: typed).exists
                redraw()
            }
        }
        facet_box_pack_start(debugRows, row("Kept in", control: directory), 0, 1, 0)

        // **Two buttons where the Mac has three.** Reveal opens the folder in whatever this desktop uses for one;
        // Empty clears the trace. There is no Copy, which on the Mac puts the file on the clipboard through
        // `NSPasteboard` -- the Linux equivalent is a save dialogue, and a file manager already has one.
        let buttons = SettingsWidgets.row(spacing: Int(SettingsMetrics.rowSpacing))
        let reveal = gtk_button_new_with_label("Show the folder")!
        SettingsWidgets.identify(reveal, "app-debug-reveal")
        gtk_widget_set_sensitive(reveal, values.hasDebugTrace ? 1 : 0)
        signals.connect(reveal, "clicked") { [weak self] in self?.revealTrace() }
        facet_box_pack_start(buttons, reveal, 0, 0, 0)

        let clear = gtk_button_new_with_label("Empty the trace")!
        SettingsWidgets.identify(clear, "app-debug-clear")
        gtk_widget_set_sensitive(clear, values.hasDebugTrace ? 1 : 0)
        signals.connect(clear, "clicked") { [weak self] in self?.clearTrace() }
        facet_box_pack_start(buttons, clear, 0, 0, 0)
        facet_box_pack_start(debugRows, row("", control: buttons), 0, 1, 0)
    }

    /// Opens the folder the trace is in.
    ///
    /// **`xdg-open`, which is this platform's `NSWorkspace`**: the desktop's own answer to "show me this", and the
    /// one thing here that is genuinely a platform capability rather than a row.
    private func revealTrace() {
        let file = DebugTraceFile.inUse(by: debugLog, directory: values.debugDirectory)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xdg-open")
        process.arguments = [file.url.deletingLastPathComponent().path]
        do {
            try process.run()
            debugLog?.record(.click, "Button clicked: Show the folder, \(file.url.deletingLastPathComponent().path)")
        } catch {
            // **Said rather than swallowed.** A button that silently does nothing is the fault `CLAUDE.md` names
            // twice, and a desktop without `xdg-open` is a real machine rather than a hypothetical one.
            debugLog?.record(.click, "The folder could not be opened: \(error.localizedDescription)")
            dialogues.tell(Dialogue(
                title: "The folder could not be opened",
                message: "Facet asked the desktop to show \(file.url.deletingLastPathComponent().path) and it "
                    + "refused. The trace is still there and can be opened by hand."
            ))
        }
    }

    /// Empties the trace file.
    private func clearTrace() {
        let file = DebugTraceFile.inUse(by: debugLog, directory: values.debugDirectory)
        debugLog?.record(.click, "Button clicked: Empty the trace")
        guard file.clear() else {
            dialogues.tell(Dialogue(
                title: "The trace could not be emptied",
                message: "Facet could not empty \(file.url.path). It may be open in something else."
            ))
            return
        }
        values.hasDebugTrace = DebugTraceFile.inUse(by: debugLog, directory: values.debugDirectory).exists
        redraw()
    }

    // MARK: - writing

    /// Writes a change, and adopts it only once the table has it.
    ///
    /// **A refused write puts the row back and says so in an alert**, which is the third of `CLAUDE.md`'s conditions
    /// for an open window holding a setting: a field still showing what was typed while the table holds something
    /// else is the two-answers problem itself. Putting it back here is a redraw from `values`, which is what the
    /// table last agreed to.
    private func apply(_ change: AppSettingsChange, adopt: @escaping () -> Void) {
        switch AppSettingWrite.apply(change, to: settings, debugLog: debugLog) {
        case .stored:
            adopt()
            // The status item draws from settings too -- `display_seconds` decides whether its figure carries them
            // -- and it repaints on a tick that only runs while something is being timed. So a setting changed
            // against a paused session would be stored and not shown, which reads as a control that did nothing.
            timingChanged()
        case let .refused(title):
            redraw()
            dialogues.tell(Dialogue(
                title: title,
                message: "Facet could not store that. The row is back to what it was."
            ))
        case .notASetting:
            break
        }
    }

    /// One labelled row: the words down the left, the control and its unit pinned to the right-hand edge.
    ///
    /// **The archive's shape, measured off `image/preferences-device.png`**, and the same one the Device tab draws:
    /// these are the two tabs made of settings rows, and two tabs of rows that sat at different rhythms would read
    /// as two windows. A control sitting wherever its label happened to end is what that looks like when it is
    /// wrong -- which it was here until it was seen on screen.
    private func row(
        _ label: String,
        control: UnsafeMutablePointer<GtkWidget>,
        suffix: String? = nil
    ) -> UnsafeMutablePointer<GtkWidget> {
        let line = SettingsWidgets.row()
        gtk_widget_set_size_request(line, -1, Int32(SettingsMetrics.rowHeight))
        if !label.isEmpty {
            facet_box_pack_start(line, SettingsWidgets.label(label), 0, 1, 0)
        }
        if let suffix {
            facet_box_pack_end(line, SettingsWidgets.secondary(suffix), 0, 0, 0)
        }
        // A row with no label of its own -- a check box, which carries its own words -- fills the line instead, or
        // it would be a tick floating at the right-hand edge with nothing to its left.
        if label.isEmpty {
            facet_box_pack_start(line, control, 1, 1, 0)
        } else {
            facet_box_pack_end(line, control, 0, 0, 0)
        }
        return line
    }
}
