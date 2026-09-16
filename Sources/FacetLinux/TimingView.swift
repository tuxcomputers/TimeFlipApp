import CGtk
import FacetCore
import Foundation

/// The Timing column: what is being timed, whether the clock is running, and for how long.
///
/// **Two pictures in one square, which is the Mac's arrangement and the archive's before it.** With nothing paired
/// it is the play/pause control, the elapsed figure and the category's name; following a cube it is the device seen
/// from above, lit in the face's colour with that category's icon on its centre face, the lock in the corner, and
/// the name and the day's figure underneath. Both occupy the same space, so the column keeps its proportions either
/// way rather than being two layouts that happen to sit in one pane.
///
/// **No clock and no play/pause in the cube picture**, which is the archive's reasoning kept: this is a picture of
/// where the cube is, and the cube's own timing is not something a click on this window starts or stops.
///
/// **It draws what it is told.** Whether the clock is running is `TimingReadout`'s to answer, what the icons mean is
/// `ManualTimerRules`', and the two clicks go back out to `FaceEdits`.
///
/// **Sized in points rather than off the square**, which is where this departs from the Mac. There every measurement
/// is a fraction of the column because the window was resizable and the artwork had to keep its proportions; this
/// window is one width, so the square is one size and a fraction of it would be a fraction of a constant. The
/// numbers that matter -- where the icon sits on the cube's centre face, where the lock sits outside the ring -- are
/// still derived from the artwork rather than chosen, because those follow the drawing and not the window.
@MainActor
final class TimingView {
    enum Layout {
        /// The square the device is drawn in. One number, this window being one width.
        static let square = 220

        /// How much of `ic_facet.svg`'s box the cube itself takes up: its mark is drawn at
        /// `translate(67.44481,67.43981) scale(5.801852)` inside a `scale(0.126953125)` group, which comes to this.
        /// The rest of the box is the ring around it.
        static let markScale = 0.736487

        /// The glyph, as a fraction of the square. The device's centre face is a regular pentagon, and the largest
        /// centred square that fits inside it is about 0.297 of the artwork's width -- the limit comes from the two
        /// upper edges meeting at the point -- so this stays just inside.
        static let glyphScale = 0.29

        /// The category's icon on the device's centre face. **`glyphScale` shrunk by the mark**, and not a number
        /// chosen by eye: 0.29 was measured against artwork whose cube filled the box, and this artwork holds the
        /// same cube at `markScale` to leave room for the ring, so the pentagon shrank by exactly that much with it.
        static var centreIcon: Int { Int((Double(square) * glyphScale * markScale).rounded()) }

        /// The lock in the corner of the square. **The margin the ring leaves, derived rather than chosen**: the cube
        /// occupies `markScale` of the box and the rest is the ring, so `(1 - markScale) / 2` is exactly the band of
        /// empty square outside it -- which is where a lock can sit without landing on the artwork.
        static var lock: Int { Int((Double(square) * (1 - markScale) / 2).rounded()) }

        /// The category's name under the square, and the figure under the name. Both in points here, where the Mac
        /// scales them off the column.
        static let nameFontSize = 24
        static let elapsedFontSize = 18
        /// The figure under the name in the cube picture, which is smaller: it qualifies the name rather than being
        /// the point of the picture the way a running clock is.
        static let faceElapsedFontSize = 12
        static let spacing = 12
    }

    /// The device seen from above, which is the app's own mark.
    static let deviceArtwork = "ic_facet"

    let widget: UnsafeMutablePointer<GtkWidget>

    /// Called when the play/pause control is pressed, which is only possible while something is being timed.
    var onTogglePause: (() -> Void)?

    /// Called when the lock in the corner is pressed, which is only drawn while a cube is being followed.
    var onToggleLock: (() -> Void)?

    /// The square and what is under it, rebuilt on each draw.
    ///
    /// **Rebuilt rather than updated**, which is this window's habit and is right here for a reason of its own: the
    /// two pictures share nothing but their place, so keeping both sets of widgets alive and swapping visibility
    /// would be two layouts to keep in step with one reading.
    private let square: UnsafeMutablePointer<GtkWidget>
    private let caption: UnsafeMutablePointer<GtkWidget>
    private var signals = GtkSignals()

    init() {
        widget = SettingsWidgets.column(spacing: Layout.spacing)
        square = SettingsWidgets.column(spacing: 0)
        gtk_widget_set_size_request(square, Int32(Layout.square), Int32(Layout.square))
        caption = SettingsWidgets.column(spacing: 4)
        facet_box_pack_start(widget, square, 0, 0, 0)
        facet_box_pack_start(widget, caption, 0, 0, 0)
    }

    /// The manual picture: the control, the running figure, and the name of what is being timed.
    ///
    /// - Parameter isLimitReached: whether the category has spent its budget for the day, which is what makes the
    ///   control inert. Drawn dead rather than hidden: the session is still there to look at.
    func show(
        category: CategoryRecord?,
        timingState: TimingState,
        elapsed: TimeInterval,
        isLimitReached: Bool = false
    ) {
        clear()
        // **Nothing at all when idle**, which is the Mac's drawing: an idle control is not drawn rather than drawn
        // inert, so there is nothing to click at.
        guard let symbol = SymbolGlyph.character(for: ManualTimerRules.symbolName(for: timingState)) else { return }

        let glyph = SettingsWidgets.plainLabel(symbol)
        facet_label_set_markup(
            glyph,
            "<span size=\"\(Int(Double(Layout.square) * Layout.glyphScale) * 1024)\"\(colourAttribute(category))>\(symbol)</span>"
        )
        gtk_widget_set_halign(glyph, GTK_ALIGN_CENTER)
        let button = SettingsWidgets.flatButton(glyph)
        SettingsWidgets.identify(button, "timing-play-pause")
        gtk_widget_set_tooltip_text(button, timingState == .running ? "Running, click to pause" : "Paused, click to resume")
        // Inert, not hidden: `ManualTimerRules` is what decides, and a spent limit is a session still worth seeing.
        gtk_widget_set_sensitive(button, ManualTimerRules.isClickable(timingState, isLimitReached: isLimitReached) ? 1 : 0)
        signals.connect(button, "clicked") { [weak self] in self?.onTogglePause?() }
        gtk_widget_set_valign(button, GTK_ALIGN_CENTER)
        gtk_widget_set_halign(button, GTK_ALIGN_CENTER)
        facet_box_pack_start(square, button, 1, 0, 0)

        let figure = SettingsWidgets.plainLabel("")
        facet_label_set_markup(
            figure,
            "<span size=\"\(Layout.elapsedFontSize * 1024)\">\(DurationFormat.hoursMinutesSeconds(elapsed, rounding: .truncate, showingSeconds: true))</span>"
        )
        SettingsWidgets.identify(figure, "timing-elapsed")
        gtk_widget_set_halign(figure, GTK_ALIGN_CENTER)
        facet_box_pack_start(square, figure, 0, 0, 0)

        name(category?.name ?? "", size: Layout.nameFontSize)
        gtk_widget_show_all(widget)
    }

    /// The cube picture: the face it is resting on, what that face holds, and the lock on it.
    ///
    /// - Parameter elapsed: the category's total for the day, since the square is the cube. `0` with no category to
    ///   total draws nothing rather than `0:00:00`: an unlit cube with a figure under it would be a number about a
    ///   category that is not there.
    /// - Parameter cubePauseState: whether the cube itself is stopped, `unknown` for one that has not answered.
    ///   Nothing is drawn for that, since a guess would be a claim about hardware on no evidence.
    func show(
        face: Int,
        category: CategoryRecord?,
        isFaceLocked: Bool = false,
        elapsed: TimeInterval = 0,
        showingSeconds: Bool = true,
        cubePauseState: CubePauseState = .unknown
    ) {
        clear()
        let holder = gtk_overlay_new()!
        gtk_widget_set_size_request(holder, Int32(Layout.square), Int32(Layout.square))
        // **Centred rather than left to fill**, which is not a preference: in a vertical `GtkBox` a child always
        // takes the box's full width whatever it was packed with, so without this the overlay is the column's width
        // and the lock in its corner is at the corner of the column rather than of the cube.
        gtk_widget_set_halign(holder, GTK_ALIGN_CENTER)
        SettingsWidgets.identify(holder, "timing-device-face", saying: "Face \(face)")

        // **What the cube is lit in, and what its lines are drawn in, are both `DeviceFaceRules`'.** Including the
        // face holding nothing, which has an answer of its own there rather than being a colour picked here -- and
        // the same two answers the cube's own LED is sent, so the picture and the hardware cannot disagree.
        let ink = DeviceFaceRules.lineColour(for: category)
        if let cube = ActivityIcon.colouredImage(
            named: Self.deviceArtwork,
            size: Layout.square,
            fill: GdkRGBA(DeviceFaceRules.bodyColour(for: category)),
            ink: GdkRGBA(ink)
        ) {
            facet_container_add(holder, cube)
        }

        // The category's icon on the centre face, in the same ink as the lines it sits between.
        if let iconName = category?.iconName,
           let icon = ActivityIcon.image(named: iconName, size: Layout.centreIcon, colour: GdkRGBA(ink)) {
            SettingsWidgets.identify(icon, "timing-centre-icon")
            gtk_widget_set_halign(icon, GTK_ALIGN_CENTER)
            gtk_widget_set_valign(icon, GTK_ALIGN_CENTER)
            facet_overlay_add(holder, icon)
        }

        // The lock in the corner, outside the ring. **Both names spelled out**, which is the Mac's decision: what a
        // control is called has to say what pressing it does, and "Lock" on a locked face reads as a label for the
        // state it is already in.
        let lock = SettingsWidgets.plainLabel("")
        facet_label_set_markup(
            lock,
            "<span size=\"\(Layout.lock * 1024)\">"
                + (SymbolGlyph.character(for: isFaceLocked ? SymbolGlyph.locked : SymbolGlyph.unlocked) ?? "")
                + "</span>"
        )
        let lockButton = SettingsWidgets.flatButton(lock)
        SettingsWidgets.identify(lockButton, "timing-face-lock", saying: isFaceLocked ? "Unlock face" : "Lock face")
        gtk_widget_set_tooltip_text(
            lockButton,
            isFaceLocked ? "Unlock this face so its category can be changed" : "Lock this face to keep its category"
        )
        signals.connect(lockButton, "clicked") { [weak self] in self?.onToggleLock?() }
        gtk_widget_set_halign(lockButton, GTK_ALIGN_END)
        gtk_widget_set_valign(lockButton, GTK_ALIGN_START)
        facet_overlay_add(holder, lockButton)

        facet_box_pack_start(square, holder, 0, 0, 0)

        name(category?.name ?? "", size: Layout.nameFontSize)
        guard category != nil else {
            gtk_widget_show_all(widget)
            return
        }
        // The figure, with the cube's own state beside it. **The glyph goes with the figure** rather than sitting
        // alone under an unlit cube: nothing to qualify means nothing to draw beside it.
        let line = SettingsWidgets.row(spacing: 6)
        gtk_widget_set_halign(line, GTK_ALIGN_CENTER)
        if let glyph = SymbolGlyph.character(for: cubePauseState.symbolName) {
            let view = SettingsWidgets.plainLabel(glyph)
            // **Said in words as well as drawn**, which is what the menu bar's line already does for the same fact.
            // A symbol is one character to anything reading the accessibility tree, so a glyph with no label cannot
            // be told from any other -- and "which one is showing" is exactly what a check is here to ask.
            SettingsWidgets.identify(view, "timing-face-glyph", saying: cubePauseState.spokenLabel)
            facet_box_pack_start(line, view, 0, 0, 0)
        }
        let figure = SettingsWidgets.plainLabel("")
        facet_label_set_markup(
            figure,
            "<span size=\"\(Layout.faceElapsedFontSize * 1024)\">"
                + DurationFormat.hoursMinutesSeconds(elapsed, rounding: .truncate, showingSeconds: showingSeconds)
                + "</span>"
        )
        SettingsWidgets.identify(figure, "timing-face-elapsed")
        facet_box_pack_start(line, figure, 0, 0, 0)
        facet_box_pack_start(caption, line, 0, 0, 0)
        gtk_widget_show_all(widget)
    }

    /// The category's name under the square.
    private func name(_ text: String, size: Int) {
        guard !text.isEmpty else { return }
        let label = SettingsWidgets.label(text)
        facet_label_set_markup(label, "<span size=\"\(size * 1024)\">\(Self.escaped(text))</span>")
        facet_label_set_xalign(label, 0.5)
        // Two lines before it is truncated, which is the Mac's `nameMaximumLines`: the second line is used when it is
        // needed rather than reserved, so nothing below the name moves for a one-word category.
        facet_label_wrap_lines(label, 2)
        SettingsWidgets.identify(label, "timing-category-name", saying: text)
        facet_box_pack_start(caption, label, 0, 0, 0)
    }

    /// Takes both pictures down.
    ///
    /// **The handlers go with the widgets**, which is the one ordering that matters here: a closure released while
    /// its button is still on screen is a press reaching a pointer to nothing.
    private func clear() {
        for child in SettingsWidgets.children(of: square) + SettingsWidgets.children(of: caption) {
            gtk_widget_destroy(child)
        }
        signals = GtkSignals()
    }

    /// The glyph takes the category's colour; nothing behind it does. It stands where the lit device would be, and
    /// the device is what carries colour as a body -- a filled tile here would be inventing an object that is not in
    /// the design. No colour set falls back to the ordinary text colour, which is what the previous app drew.
    private func colourAttribute(_ category: CategoryRecord?) -> String {
        guard let colour = category?.colour else { return "" }
        let channels = [colour.red, colour.green, colour.blue]
        return " foreground=\"#" + channels.map { String(format: "%02X", Int(($0 * 255).rounded())) }.joined() + "\""
    }

    private static func escaped(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}

extension GdkRGBA {
    /// One of the palette's colours as GTK holds them. Both are four components in `0...1`, so this is a spelling
    /// rather than a conversion -- `Colour` is sRGB and says why it can only be sRGB.
    init(_ colour: Colour) {
        self.init(red: colour.red, green: colour.green, blue: colour.blue, alpha: colour.alpha)
    }
}
