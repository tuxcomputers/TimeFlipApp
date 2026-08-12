import SwiftUI

/// A number you can type into or hold an arrow to run through. Every typeable value in the Settings
/// window is one of these: the App tab's settings rows, and the Device tab's auto-pause, LED
/// brightness and blink interval, and four double-tap params.
///
/// The arrows repeat while held, and accelerate exactly as the auto-pause field does: ticks of 1
/// until the value passes the second multiple of 5 beyond where the hold began, then ticks of 5 at
/// a slower cadence (see `AutoPauseStepper`, which is the whole of that logic and is unit tested on
/// its own). Every stepper in the window shares it, so none of them feels different from the rest --
/// which matters most on the wide ranges, where stepping by 1 the whole way makes crossing them a
/// chore.
///
/// Typing is committed on Return or when the field loses focus, never per keystroke -- a
/// keystroke-by-keystroke commit would clamp "1" on the way to "15" and fight the user. The draft is
/// resynced from the value whenever the arrows move it, including while the field still has focus,
/// and clamped locally on commit so an out-of-range entry snaps back to what was actually stored
/// rather than sitting there as typed.
///
/// **An arrow steps from the number on screen, not from the number in storage.** Type 20 into a
/// field holding 5, click up without pressing Return, and you get 21: the visible text is what the
/// user believes the value to be, so treating it as a waypoint is the only reading that matches the
/// screen. `stepBase(draft:storedValue:range:)` is that rule, and it is unit tested on its own.
struct SteppedNumberField: View {
    @ObservedObject var appState: AppState
    /// Distinguishes this control's arrows from the other rows' -- see `AppState.steppedFieldHoldKey`.
    let holdKey: String
    let value: Int
    let range: ClosedRange<Int>
    /// Shown after the field, e.g. `%`. Empty for a bare number.
    let suffix: String
    let fieldWidth: CGFloat
    /// A fixed slot for the suffix, so the arrows after it land at a width the caller can predict
    /// rather than wherever the suffix's own text happens to end. `nil` lets it size to its text.
    var suffixWidth: CGFloat? = nil
    let onCommit: (Int) -> Void

    @State private var draft: String = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: SettingsLayoutConstants.Stepper.itemSpacing) {
            TextField("", text: $draft)
                .textFieldStyle(.roundedBorder)
                .labelsHidden()
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
                .frame(width: fieldWidth)
                .focused($isFocused)
                .onSubmit(commitDraft)
                .onChange(of: isFocused) { _, focused in
                    if focused {
                        draft = "\(value)"
                    } else {
                        commitDraft()
                    }
                }
                .onChange(of: value) { _, newValue in
                    // Don't overwrite what is being typed. This only suppresses changes arriving
                    // from elsewhere (another view writing the same setting); an arrow resyncs the
                    // draft itself, in `commit`, so it stays visible while the field holds focus.
                    guard !isFocused else { return }
                    draft = "\(newValue)"
                }
                .onAppear { draft = "\(value)" }
            if !suffix.isEmpty {
                Text(suffix)
                    .foregroundStyle(.secondary)
                    .frame(width: suffixWidth, alignment: .leading)
            } else if let suffixWidth {
                // A row with nothing to say after its number still holds the slot open, so its
                // arrows land in the same column as every other row's rather than sliding left into
                // the space the suffix would have taken. The double-tap fields are the ones that
                // need this.
                Color.clear.frame(width: suffixWidth, height: 0)
            }
            VStack(spacing: SettingsLayoutConstants.Stepper.arrowSpacing) {
                arrow("chevron.up", delta: 1)
                arrow("chevron.down", delta: -1)
            }
        }
    }

    private func arrow(_ systemImage: String, delta: Int) -> some View {
        let key = "\(holdKey):\(delta)"
        return Image(systemName: systemImage)
            .font(.system(size: SettingsLayoutConstants.Stepper.arrowPointSize, weight: .bold))
            .foregroundStyle(.secondary)
            .frame(width: SettingsLayoutConstants.Stepper.arrowsWidth, height: SettingsLayoutConstants.Stepper.arrowHeight)
            .contentShape(Rectangle())
            .onLongPressGesture(minimumDuration: 0, maximumDistance: 50, pressing: { isPressing in
                if isPressing {
                    guard appState.steppedFieldHoldKey != key else { return }
                    appState.steppedFieldHoldKey = key
                    // The value the hold began at, kept for the whole hold: `AutoPauseStepper`
                    // measures its step-1-then-step-5 boundary from there, not from wherever the
                    // value has since reached. Taken from the field's text rather than from
                    // `value`, so a hold begun after typing accelerates from where the user can
                    // see it is starting.
                    let holdStartValue = Self.stepBase(draft: draft, storedValue: value, range: range)
                    // The typed number is a choice the user made, so store it before stepping off
                    // it. Skipped when it already matches, which is every press on a field nobody
                    // has typed into. It matters when the step cannot move: type 30 into a field
                    // capped at 30 and press up, and without this the 30 would sit on screen
                    // unstored until the field lost focus.
                    if holdStartValue != value {
                        onCommit(holdStartValue)
                    }
                    let afterFirstTick = step(delta, from: holdStartValue)
                    beginHold(delta: delta, holdStartValue: holdStartValue, from: afterFirstTick)
                } else if appState.steppedFieldHoldKey == key {
                    appState.cancelSteppedFieldHold()
                }
            }, perform: {})
    }

    /// Where an arrow press counts from: the field's own text when that is a number, clamped to
    /// `range`, and the stored value when it is not.
    ///
    /// The two disagree only while the field has focus and the typed entry is uncommitted, since a
    /// blurred field's draft is kept in step with the value. Garbage falls back to the stored value
    /// rather than to zero, matching `commitDraft`, which reverts an unparseable entry for the same
    /// reason: the last number the user actually chose beats one invented from nothing. Clamping
    /// here is what makes the arrows work at all after an out-of-range entry -- typing 99 into a
    /// field capped at 30 and pressing down has to go to 29, not to 98.
    static func stepBase(draft: String, storedValue: Int, range: ClosedRange<Int>) -> Int {
        guard let typed = Int(draft.trimmingCharacters(in: .whitespaces)) else { return storedValue }
        return min(range.upperBound, max(range.lowerBound, typed))
    }

    /// One tick of 1 from `current`, which the caller has already resolved through `stepBase`.
    @discardableResult
    private func step(_ delta: Int, from current: Int) -> Int {
        commit(current + delta, from: current)
    }

    /// Stores `target`, clamped to `range`. Returns the value now held, unchanged when the clamp
    /// meant it didn't move -- which is how a held arrow knows it has reached an end and can stop.
    @discardableResult
    private func commit(_ target: Int, from current: Int) -> Int {
        let clamped = min(range.upperBound, max(range.lowerBound, target))
        // Before the early return, not after, and this is the whole bug this control had: an arrow
        // pressed while the field held focus moved the value and left the text saying what it said
        // before, because the only resync was an onChange that steps aside for a focused field.
        // Unconditional also covers the arrow that cannot move: type 99 into a field capped at 30,
        // press up, and the text still has to fall back to 30 rather than sit there reading 99.
        draft = "\(clamped)"
        guard clamped != current else { return current }
        onCommit(clamped)
        return clamped
    }

    /// Starts the repeat loop for a held arrow, counting on from `start`.
    ///
    /// The running total is a local variable rather than a re-read of `value`, because `value` is a
    /// plain property: the struct copy this task captured keeps the pre-hold number for the whole
    /// hold, so re-reading it would re-commit the same single step on every tick and the value would
    /// appear to move once and then stick. (The auto-pause loop can re-read its equivalent only
    /// because that one is `@State`, which reads through a box that outlives the copy.) A held arrow
    /// is the only thing changing the value while it's down, so counting locally stays accurate.
    private func beginHold(delta: Int, holdStartValue: Int, from start: Int) {
        appState.steppedFieldHoldTask?.cancel()
        appState.steppedFieldHoldTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(AutoPauseStepper.initialHoldDelay * 1_000_000_000))
            var current = start
            while !Task.isCancelled {
                let target = AutoPauseStepper.nextValue(
                    current: current, holdStartValue: holdStartValue, direction: delta
                )
                let next = commit(target, from: current)
                // Stop rather than spin once an end of the range is reached.
                guard next != current else { return }
                current = next
                // The wait before the *next* tick is measured from the value just reached, not the
                // one before it -- otherwise the first tick after crossing the boundary fires at
                // the fast single-digit cadence instead of the slower step-5 one.
                let interval = AutoPauseStepper.tickInterval(
                    current: next, holdStartValue: holdStartValue, direction: delta
                )
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }
    }

    private func commitDraft() {
        guard let typed = Int(draft.trimmingCharacters(in: .whitespaces)) else {
            draft = "\(value)"
            return
        }
        let clamped = min(range.upperBound, max(range.lowerBound, typed))
        draft = "\(clamped)"
        guard clamped != value else { return }
        onCommit(clamped)
    }
}
