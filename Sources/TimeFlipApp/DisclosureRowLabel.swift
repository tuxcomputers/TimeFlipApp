import SwiftUI

/// The label of a collapsible row, clickable across the whole row rather than only where the text
/// sits.
///
/// A bare `Text` label hugs its own width, which leaves most of the row dead to a click even though
/// the row plainly is one control: the `Spacer` claims the rest of the width and `contentShape` makes
/// that empty space part of the hit area. The disclosure chevron keeps working as it always did.
struct DisclosureRowLabel: View {
    let title: String
    /// What the click log calls this row, for when that isn't the title itself -- the Categories tab
    /// shows "Active" but logs "Active categories".
    let logName: String
    let isExpanded: Bool
    let toggle: () -> Void

    init(_ title: String, logName: String? = nil, isExpanded: Bool, toggle: @escaping () -> Void) {
        self.title = title
        self.logName = logName ?? title
        self.isExpanded = isExpanded
        self.toggle = toggle
    }

    var body: some View {
        Button {
            DeveloperMode.debugPrint(.click, "Button clicked: \(logName) (\(isExpanded ? "collapse" : "expand"))")
            toggle()
        } label: {
            HStack {
                Text(title)
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
