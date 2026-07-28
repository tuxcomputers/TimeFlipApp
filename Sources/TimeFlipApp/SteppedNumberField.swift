import SwiftUI

/// A number you can type into or hold an arrow to run through, shared by the App tab's settings rows
/// and the Device tab's LED brightness and blink interval.
///
/// The arrows repeat while held, matching the Device tab's auto-pause stepper (same initial delay
/// and tick cadence, see `AutoPauseStepper`) so every stepper in the window feels the same. Unlike
/// that one the step is always 1: these ranges are small enough that accelerating through them buys
/// nothing.
///
/// Typing is committed on Return or when the field loses focus, never per keystroke -- a
/// keystroke-by-keystroke commit would clamp "1" on the way to "15" and fight the user. The draft is
/// resynced from the value whenever the arrows move it, and clamped locally on commit so an
/// out-of-range entry snaps back to what was actually stored rather than sitting there as typed.
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
                    // Don't overwrite what is being typed; the commit path resyncs instead.
                    guard !isFocused else { return }
                    draft = "\(newValue)"
                }
                .onAppear { draft = "\(value)" }
            if !suffix.isEmpty {
                Text(suffix)
                    .foregroundStyle(.secondary)
                    .frame(width: suffixWidth, alignment: .leading)
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
                    beginHold(delta: delta, from: step(delta, from: value))
                } else if appState.steppedFieldHoldKey == key {
                    appState.cancelSteppedFieldHold()
                }
            }, perform: {})
    }

    /// One tick, stepping from `current` rather than from the draft, so a half-typed entry can't be
    /// used as the starting point. Returns the value now stored, unchanged if the step was clamped.
    @discardableResult
    private func step(_ delta: Int, from current: Int) -> Int {
        let stepped = min(range.upperBound, max(range.lowerBound, current + delta))
        guard stepped != current else { return current }
        onCommit(stepped)
        return stepped
    }

    /// Starts the repeat loop for a held arrow, counting on from `start`.
    ///
    /// The running total is a local variable rather than a re-read of `value`, because `value` is a
    /// plain property: the struct copy this task captured keeps the pre-hold number for the whole
    /// hold, so re-reading it would re-commit the same single step on every tick and the value would
    /// appear to move once and then stick. (The auto-pause loop can re-read its equivalent only
    /// because that one is `@State`, which reads through a box that outlives the copy.) A held arrow
    /// is the only thing changing the value while it's down, so counting locally stays accurate.
    private func beginHold(delta: Int, from start: Int) {
        appState.steppedFieldHoldTask?.cancel()
        appState.steppedFieldHoldTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(AutoPauseStepper.initialHoldDelay * 1_000_000_000))
            var current = start
            while !Task.isCancelled {
                let next = step(delta, from: current)
                // Stop rather than spin once an end of the range is reached.
                guard next != current else { return }
                current = next
                try? await Task.sleep(nanoseconds: UInt64(AutoPauseStepper.singleStepInterval * 1_000_000_000))
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
