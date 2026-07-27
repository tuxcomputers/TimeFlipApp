import SwiftUI

struct CategoriesSettingsView: View {
    @ObservedObject var appState: AppState
    let loadCategories: () -> [CategoryRecord]
    let updateCategoryColour: (Int, Int) -> Void
    let updateCategoryDailyLimit: (Int, Int) -> Void
    let updateCategoryActive: (Int, Bool) -> Void
    @State private var categories: [CategoryRecord] = []
    // Active is the section you actually work in, so it starts open; Inactive is the archive you
    // only occasionally go looking in, so it starts folded away.
    @State private var isActiveExpanded = true
    @State private var isInactiveExpanded = false

    var body: some View {
        Form {
            CategorySection(
                title: "Active",
                isExpanded: $isActiveExpanded,
                categories: categories.filter(\.isActive),
                emptyMessage: "No active categories.",
                appState: appState,
                actions: actions
            )
            CategorySection(
                title: "Inactive",
                isExpanded: $isInactiveExpanded,
                categories: categories.filter { !$0.isActive },
                emptyMessage: "No inactive categories.",
                appState: appState,
                actions: actions
            )
        }
        .formStyle(.grouped)
        .onAppear {
            categories = loadCategories()
        }
    }

    /// Every edit writes to the database and then patches the loaded record in place. Keeping the
    /// list the single source of truth is what lets a row move between the two sections the moment
    /// its Active checkbox changes -- and it is also why the rows hold no edit state of their own:
    /// moving a row between sections rebuilds it, and any @State it carried would reset to
    /// whatever the row was loaded with, silently reverting edits made since.
    private var actions: CategoryRowActions {
        CategoryRowActions(
            setColour: { categoryID, colourID in
                updateCategoryColour(categoryID, colourID)
                patch(categoryID) { $0.with(colourID: colourID) }
            },
            setDailyLimit: { categoryID, minutes in
                updateCategoryDailyLimit(categoryID, minutes)
                patch(categoryID) { $0.with(dailyLimitMinutes: minutes) }
            },
            setActive: { categoryID, isActive in
                updateCategoryActive(categoryID, isActive)
                patch(categoryID) { $0.with(isActive: isActive) }
            }
        )
    }

    private func patch(_ categoryID: Int, _ transform: (CategoryRecord) -> CategoryRecord) {
        guard let index = categories.firstIndex(where: { $0.id == categoryID }) else { return }
        categories[index] = transform(categories[index])
    }
}

/// The three edits a category row can make, bundled so they travel together down to the row.
struct CategoryRowActions {
    let setColour: (Int, Int) -> Void
    let setDailyLimit: (Int, Int) -> Void
    let setActive: (Int, Bool) -> Void
}

/// One collapsible group of categories, built like the Device tab's LED/More groups: the label is
/// a plain-styled Button that drives the same `isExpanded` binding, so clicking the text toggles
/// the group rather than only the disclosure chevron doing it.
private struct CategorySection: View {
    let title: String
    @Binding var isExpanded: Bool
    let categories: [CategoryRecord]
    let emptyMessage: String
    @ObservedObject var appState: AppState
    let actions: CategoryRowActions

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: SettingsLayoutConstants.CategoryList.rowSpacing) {
                if categories.isEmpty {
                    Text(emptyMessage)
                        .foregroundStyle(.secondary)
                } else {
                    CategoryColumnHeaderRow()
                    ForEach(categories) { category in
                        CategoryRow(
                            category: category,
                            colourOptions: appState.colourOptions,
                            noColourName: appState.noColourName,
                            actions: actions
                        )
                    }
                }
            }
            .padding(.vertical, SettingsLayoutConstants.CategoryList.sectionVerticalPadding)
        } label: {
            Button {
                DeveloperMode.debugPrint(.click, "Button clicked: \(title) categories (\(isExpanded ? "collapse" : "expand"))")
                isExpanded.toggle()
            } label: {
                Text(title)
            }
            .buttonStyle(.plain)
        }
    }
}

/// Column labels above the category list, aligned to `CategoryRow`'s own column widths so each
/// label sits directly over its column -- no label over the icon column, since there's nothing
/// meaningful to caption there.
private struct CategoryColumnHeaderRow: View {
    var body: some View {
        HStack(spacing: SettingsLayoutConstants.FacetList.rowSpacing) {
            Color.clear
                .frame(width: SettingsLayoutConstants.FacetList.iconSize, height: 1)
            Text("Name")
                .frame(width: SettingsLayoutConstants.CategoryList.nameColumnWidth, alignment: .leading)
            Text("Colour")
                .frame(width: SettingsLayoutConstants.CategoryList.colourColumnWidth, alignment: .leading)
            Text("Daily limit (0 = disabled)")
                .frame(width: SettingsLayoutConstants.CategoryList.limitColumnWidth, alignment: .leading)
            Text("Active")
            Spacer()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

private struct CategoryRow: View {
    let category: CategoryRecord
    let colourOptions: [ActivityColorOption]
    let noColourName: String
    let actions: CategoryRowActions
    @State private var isColorPickerPresented = false

    /// `nil` for the None colour (colour_id 0), which has no hex and so never appears in
    /// `colourOptions` -- drawn as a hollow black square rather than a solid fill, so it reads as
    /// "no colour set" instead of an actual colour choice.
    private var swatchColor: Color? {
        colourOptions.first { $0.colourId == category.colourID }?.color
    }

    var body: some View {
        HStack(spacing: SettingsLayoutConstants.FacetList.rowSpacing) {
            ActivityIconView(
                iconName: category.iconName,
                tint: .black,
                size: SettingsLayoutConstants.FacetList.iconSize
            )
            Text(category.name)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: SettingsLayoutConstants.CategoryList.nameColumnWidth, alignment: .leading)
            colourSwatch
                .frame(width: SettingsLayoutConstants.CategoryList.colourColumnWidth, alignment: .leading)
            dailyLimitField
                .frame(width: SettingsLayoutConstants.CategoryList.limitColumnWidth, alignment: .leading)
                // An inactive category is retired, kept only so historical time_entry rows still
                // resolve, so its colour and limit are a record of what it was rather than
                // settings worth carrying on tuning. The Active tick box stays live, since
                // reinstating the category is the one edit an inactive row must still allow.
                .disabled(!category.isActive)
            activeCheckbox
            Spacer()
        }
    }

    private var colourSwatch: some View {
        Button {
            DeveloperMode.debugPrint(.click, "Button clicked: Category color swatch \"\(category.name)\" (\(isColorPickerPresented ? "close" : "open") picker)")
            isColorPickerPresented.toggle()
        } label: {
            RoundedRectangle(cornerRadius: SettingsLayoutConstants.ColorPicker.rowSwatchCornerRadius)
                .fill(swatchColor ?? Color.clear)
                .overlay(
                    RoundedRectangle(cornerRadius: SettingsLayoutConstants.ColorPicker.rowSwatchCornerRadius)
                        .stroke(swatchColor == nil ? Color.black : Color.secondary.opacity(SettingsLayoutConstants.ColorPicker.swatchStrokeOpacity))
                )
                .frame(
                    width: SettingsLayoutConstants.ColorPicker.rowSwatchSize,
                    height: SettingsLayoutConstants.ColorPicker.rowSwatchSize
                )
                // A Color.clear fill (the hollow None-colour case) has no hit-testable area of its
                // own -- without this, only the 1pt stroke line would register a click.
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!category.isActive)
        .popover(isPresented: $isColorPickerPresented) {
            ColorOptionList(
                // The list writes the picked Color straight back through this binding, but the
                // record needs the colour_id that comes with onPick -- so onPick is the path that
                // actually applies the change, and this only feeds the list's own checkmark.
                selection: Binding(get: { swatchColor ?? .clear }, set: { _ in }),
                colourOptions: colourOptions,
                onPick: { option in actions.setColour(category.id, option.colourId) },
                onSelect: { isColorPickerPresented = false },
                noneOptionName: noColourName
            )
        }
    }

    /// Whole minutes per day, 0 = disabled. Deliberately uncapped, unlike the Device tab's
    /// auto-pause (the device's own protocol caps that at 240m) -- this is an app-side budget, so
    /// there is no upper bound to enforce. Negative input is clamped to 0 on commit.
    private var dailyLimitField: some View {
        HStack(spacing: SettingsLayoutConstants.CategoryList.limitFieldSpacing) {
            TextField(
                "",
                value: Binding(
                    get: { category.dailyLimitMinutes },
                    set: { applyDailyLimit(newValue: $0) }
                ),
                format: .number
            )
            .frame(width: SettingsLayoutConstants.CategoryList.limitFieldWidth)
            .labelsHidden()
            .multilineTextAlignment(.trailing)
            Text("min")
                .foregroundStyle(.secondary)
        }
    }

    /// Unticking moves the row straight to the Inactive group, and ticking it there moves it back
    /// -- the list this row was built from is re-partitioned by the same edit that writes the
    /// change, so the row lands in the matching group on the next render.
    private var activeCheckbox: some View {
        Toggle("", isOn: Binding(
            get: { category.isActive },
            set: { newValue in
                DeveloperMode.debugPrint(.click, "Button clicked: Category \"\(category.name)\" active -> \(newValue)")
                actions.setActive(category.id, newValue)
            }
        ))
        .toggleStyle(.checkbox)
        .labelsHidden()
    }

    private func applyDailyLimit(newValue: Int) {
        let clamped = max(0, newValue)
        guard clamped != category.dailyLimitMinutes else { return }
        DeveloperMode.debugPrint(.field, "Field changed: Category \"\(category.name)\" daily limit: \(category.dailyLimitMinutes)m -> \(clamped)m")
        actions.setDailyLimit(category.id, clamped)
    }
}
