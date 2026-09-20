import CGtk
import FacetCore
import Foundation

/// A number with an arrow above and an arrow below it, which is what every settable figure in this window is.
///
/// **The Linux half of `FacetMac/SteppedNumberField`, built to the same shape on purpose.** It replaced a bare
/// `GtkSpinButton` on 2026-09-20. The spin button looked right and behaved right, and it was the wrong answer for
/// one reason that only shows up from outside: **its arrows are not separate accessible objects**. It reports no
/// children and one action, so a scripted check can neither press an arrow nor count one -- and the suite does both.
/// `63-led-settings` decides whether a section is folded by counting `device-led-brightness-up`, and `00-setup`
/// steps auto-pause to nothing by pressing `device-auto-pause-up` and then `-down`.
///
/// So the arrows here are real buttons carrying `<identifier>-up` and `<identifier>-down`, exactly as the Mac's are,
/// and the field carries the identifier itself. The same check drives both platforms.
///
/// **Held by whoever built it.** Like `EditableNameCell`, this owns the handlers on its own widgets and GTK retains
/// the widgets rather than the Swift object around them, so a pane that drops its reference gets a field that draws
/// and does nothing.
@MainActor
final class SteppedNumberField {
    /// How long a held arrow waits before it starts repeating, and how fast it repeats after that.
    ///
    /// **A hold is a different gesture from a click and both are tested.** The Mac's `HoldArrow` takes over
    /// `mouseDown` for the repeat and leaves the single step to the action path; here the button's `clicked` is the
    /// single step and a press-and-hold starts the timer. `04-categories` holds an arrow for three seconds and
    /// expects the figure to have run, which one step per press cannot do.
    static let holdDelayMilliseconds: UInt32 = 500
    static let repeatMilliseconds: UInt32 = 90

    /// The row this built: the label, the field, its arrows and the suffix.
    let widget: UnsafeMutablePointer<GtkWidget>

    private let entry: UnsafeMutablePointer<GtkWidget>
    private let range: ClosedRange<Int>
    private let onChange: (Int) -> Void
    private let signals = GtkSignals()

    /// What the field holds. **Not a second copy of the setting**: it is what was last drawn or typed, and every
    /// change goes out through `onChange` at once, which is what writes it. The window's licence in `CLAUDE.md`
    /// covers exactly this.
    private var value: Int

    /// The repeat in progress, if an arrow is being held.
    private var holdSource: UInt32 = 0
    private var holdDirection = 0

    /// A boxed repeat, for the same reason `GtkSignals` boxes a handler: a Swift closure cannot cross into C, and
    /// `g_timeout_add` takes a bare function pointer and a `void *`. Kept until this field goes.
    private final class Repeat {
        let run: () -> Bool
        init(_ run: @escaping () -> Bool) { self.run = run }
    }
    private var repeats: [Repeat] = []

    init(
        value: Int,
        range: ClosedRange<Int>,
        suffix: String,
        identifier: String,
        live: Bool,
        onChange: @escaping (Int) -> Void
    ) {
        self.value = range.clamp(value)
        self.range = range
        self.onChange = onChange

        entry = gtk_entry_new()!
        facet_entry_set_text(entry, String(self.value))
        facet_entry_set_width_chars(entry, 4)
        SettingsWidgets.identify(entry, identifier, saying: String(self.value))
        gtk_widget_set_sensitive(entry, live ? 1 : 0)

        let up = SteppedNumberField.arrow("\u{25B2}", "\(identifier)-up", live: live)
        let down = SteppedNumberField.arrow("\u{25BC}", "\(identifier)-down", live: live)

        let arrows = SettingsWidgets.column(spacing: 0)
        facet_box_pack_start(arrows, up, 0, 0, 0)
        facet_box_pack_start(arrows, down, 0, 0, 0)

        let line = SettingsWidgets.row(spacing: Int(SettingsMetrics.rowSpacing))
        facet_box_pack_start(line, entry, 0, 0, 0)
        facet_box_pack_start(line, arrows, 0, 0, 0)
        if !suffix.isEmpty {
            let unit = SettingsWidgets.secondary(suffix)
            gtk_widget_set_sensitive(unit, live ? 1 : 0)
            facet_box_pack_start(line, unit, 0, 0, 0)
        }
        widget = line

        wire(up, direction: 1)
        wire(down, direction: -1)

        // **Committed on Enter and on losing focus, never per keystroke.** `CLAUDE.md` is explicit about this: a
        // value being typed into is not re-read underneath whoever is typing, because that clamps `1` on the way
        // to `15`.
        signals.connect(entry, "activate") { [weak self] in self?.commitWhatWasTyped() }
        signals.connectEvent(entry, "focus-out-event") { [weak self] _ in
            self?.commitWhatWasTyped()
            return false
        }
    }

    deinit {
        facet_source_remove(holdSource)
    }

    private static func arrow(
        _ glyph: String,
        _ identifier: String,
        live: Bool
    ) -> UnsafeMutablePointer<GtkWidget> {
        let button = SettingsWidgets.flatButton(SettingsWidgets.plainLabel(glyph))
        SettingsWidgets.identify(button, identifier, saying: glyph)
        gtk_widget_set_sensitive(button, live ? 1 : 0)
        return button
    }

    private func wire(_ button: UnsafeMutablePointer<GtkWidget>, direction: Int) {
        signals.connect(button, "clicked") { [weak self] in self?.step(by: direction) }

        // **The press starts the repeat and the release ends it**, which is the pair `HoldArrow` makes on the other
        // platform. `clicked` still fires on release, so a plain click is one step and a hold is one step plus the
        // repeats -- the same as a stepper anywhere else.
        signals.connectEvent(button, "button-press-event") { [weak self] _ in
            self?.beginHolding(direction)
            return false
        }
        signals.connectEvent(button, "button-release-event") { [weak self] _ in
            self?.stopHolding()
            return false
        }
        // A pointer that leaves the button while held is a hold that has ended, as far as the control is concerned.
        signals.connectEvent(button, "leave-notify-event") { [weak self] _ in
            self?.stopHolding()
            return false
        }
    }

    /// **Slow once, then fast**, which is what a stepper does everywhere: a held arrow waits before it runs away,
    /// so that a hold that was meant as a click is still a click.
    private func beginHolding(_ direction: Int) {
        stopHolding()
        holdDirection = direction
        holdSource = schedule(after: Self.holdDelayMilliseconds) { [weak self] in
            guard let self else { return false }
            step(by: holdDirection)
            holdSource = schedule(after: Self.repeatMilliseconds) { [weak self] in
                guard let self else { return false }
                self.step(by: self.holdDirection)
                return true
            }
            // This one has done its job: the faster one above has taken over.
            return false
        }
    }

    private func stopHolding() {
        facet_source_remove(holdSource)
        holdSource = 0
        holdDirection = 0
    }

    /// A `g_timeout` whose callback is a Swift closure. Answering `true` keeps it running.
    private func schedule(after milliseconds: UInt32, _ run: @escaping () -> Bool) -> UInt32 {
        let holder = Repeat(run)
        repeats.append(holder)
        return facet_timeout_add(
            milliseconds,
            { data in
                guard let data else { return facet_source_remove_value() }
                return MainActor.assumeIsolated {
                    let again = Unmanaged<Repeat>.fromOpaque(data).takeUnretainedValue().run()
                    return again ? facet_source_continue() : facet_source_remove_value()
                }
            },
            Unmanaged.passUnretained(holder).toOpaque()
        )
    }

    private func step(by direction: Int) {
        set(value + direction)
    }

    private func commitWhatWasTyped() {
        let typed = facet_entry_get_text(entry).map { String(cString: $0) } ?? ""
        guard let number = Int(typed.trimmingCharacters(in: .whitespaces)) else {
            // Put back what the field is actually on, rather than leaving words in a number field.
            show(value)
            return
        }
        set(number)
    }

    private func set(_ wanted: Int) {
        let clamped = range.clamp(wanted)
        show(clamped)
        guard clamped != value else { return }
        value = clamped
        onChange(clamped)
    }

    private func show(_ number: Int) {
        facet_entry_set_text(entry, String(number))
        facet_set_accessible_description(entry, String(number))
    }
}

private extension ClosedRange where Bound == Int {
    func clamp(_ value: Int) -> Int {
        Swift.min(Swift.max(value, lowerBound), upperBound)
    }
}
