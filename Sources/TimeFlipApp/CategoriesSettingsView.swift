import SwiftUI

struct CategoriesSettingsView: View {
    @ObservedObject var appState: AppState
    let loadCategories: () -> [CategoryRecord]
    let updateCategoryColour: (Int, Int) -> Void
    let updateCategoryDailyLimit: (Int, Int) -> Void
    let updateCategoryActive: (Int, Bool) -> Void
    let updateCategoryIcon: (Int, Int) -> Void
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
            },
            setIcon: { categoryID, iconID in
                updateCategoryIcon(categoryID, iconID)
                patch(categoryID) { $0.with(iconID: iconID) }
            }
        )
    }

    private func patch(_ categoryID: Int, _ transform: (CategoryRecord) -> CategoryRecord) {
        guard let index = categories.firstIndex(where: { $0.id == categoryID }) else { return }
        categories[index] = transform(categories[index])
    }
}

/// The edits a category row can make, bundled so they travel together down to the row.
struct CategoryRowActions {
    let setColour: (Int, Int) -> Void
    let setDailyLimit: (Int, Int) -> Void
    let setActive: (Int, Bool) -> Void
    let setIcon: (Int, Int) -> Void
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
                            iconOptions: appState.iconOptions,
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
    let iconOptions: [CategoryIconOption]
    let actions: CategoryRowActions
    @State private var isColorPickerPresented = false
    @State private var isIconPickerPresented = false

    /// `nil` for the None icon (icon_id 0), which is a sentinel rather than a bundled asset and so
    /// never appears in `iconOptions`.
    private var iconName: String? {
        iconOptions.first { $0.iconId == category.iconID }?.iconName
    }

    /// `nil` for the None colour (colour_id 0), which has no hex and so never appears in
    /// `colourOptions` -- drawn as a hollow black square rather than a solid fill, so it reads as
    /// "no colour set" instead of an actual colour choice.
    private var swatchColor: Color? {
        colourOptions.first { $0.colourId == category.colourID }?.color
    }

    var body: some View {
        HStack(spacing: SettingsLayoutConstants.FacetList.rowSpacing) {
            iconButton
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

    /// Opens the icon grid. An unset icon (icon_id 0) shows the same "no icon" glyph the Faces
    /// grid uses for its none cell, so the two pages read the same way.
    private var iconButton: some View {
        Button {
            DeveloperMode.debugPrint(.click, "Button clicked: Category icon \"\(category.name)\" (\(isIconPickerPresented ? "close" : "open") picker)")
            isIconPickerPresented.toggle()
        } label: {
            Group {
                if let iconName {
                    ActivityIconView(
                        iconName: iconName,
                        tint: .black,
                        size: SettingsLayoutConstants.FacetList.iconSize
                    )
                } else {
                    Image(systemName: "nosign")
                        .resizable()
                        .scaledToFit()
                        .foregroundStyle(.secondary)
                        .frame(
                            width: SettingsLayoutConstants.FacetList.iconSize,
                            height: SettingsLayoutConstants.FacetList.iconSize
                        )
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!category.isActive)
        .popover(isPresented: $isIconPickerPresented) {
            CategoryIconGrid(
                iconOptions: iconOptions,
                selectedIconID: category.iconID
            ) { iconID in
                actions.setIcon(category.id, iconID)
                isIconPickerPresented = false
            }
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

/// The Categories tab's icon picker: every real icon (`icon_id >= 1`) in a fixed 6-wide grid, so
/// the 42 seeded icons land as an even 6x7 with no scrolling.
///
/// There is no "none" cell, unlike the Faces tab's grid. Clicking the already-selected icon clears
/// it instead, writing `icon_id` 0 -- so the same click both sets and unsets, and the grid stays a
/// clean rectangle of real choices.
///
/// Icons draw black here rather than in the category's colour: the Faces grid tints to preview how
/// the icon will look on the device, but nothing on this tab is previewing a device face.
private struct CategoryIconGrid: View {
    let iconOptions: [CategoryIconOption]
    let selectedIconID: Int
    let onPick: (Int) -> Void

    private var columns: [GridItem] {
        Array(
            repeating: GridItem(
                .fixed(SettingsLayoutConstants.IconGrid.cellSize),
                spacing: SettingsLayoutConstants.IconGrid.columnSpacing
            ),
            count: SettingsLayoutConstants.CategoryList.iconGridColumns
        )
    }

    var body: some View {
        LazyVGrid(columns: columns, spacing: SettingsLayoutConstants.IconGrid.columnSpacing) {
            ForEach(iconOptions) { option in
                let isSelected = option.iconId == selectedIconID
                CategoryIconGridCell(
                    iconName: option.iconName,
                    isSelected: isSelected
                ) {
                    // Re-clicking the selected icon clears it; anything else selects it.
                    let newIconID = isSelected ? 0 : option.iconId
                    DeveloperMode.debugPrint(.click, "Button clicked: Icon grid cell (\(option.iconName)) -> icon_id \(newIconID)")
                    onPick(newIconID)
                }
                .help(option.name)
            }
        }
        .padding(SettingsLayoutConstants.IconGrid.gridVerticalPadding)
    }
}

private struct CategoryIconGridCell: View {
    let iconName: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                RoundedRectangle(cornerRadius: SettingsLayoutConstants.IconGrid.cellCornerRadius)
                    .fill(Color(NSColor.controlBackgroundColor))
                    .overlay(
                        RoundedRectangle(cornerRadius: SettingsLayoutConstants.IconGrid.cellCornerRadius)
                            .stroke(strokeColor, lineWidth: strokeWidth)
                    )
                if let image = ActivityIconLoader.image(
                    named: iconName,
                    pointSize: SettingsLayoutConstants.IconGrid.iconPointSize
                ) {
                    Image(nsImage: image)
                        .resizable()
                        .renderingMode(.template)
                        .foregroundStyle(Color.black)
                        .scaledToFit()
                        .padding(SettingsLayoutConstants.IconGrid.cellPadding)
                } else {
                    Image(systemName: "square.dashed")
                        .resizable()
                        .scaledToFit()
                        .foregroundStyle(.secondary)
                        .padding(SettingsLayoutConstants.IconGrid.cellPadding)
                }
            }
            .frame(
                width: SettingsLayoutConstants.IconGrid.cellSize,
                height: SettingsLayoutConstants.IconGrid.cellSize
            )
        }
        .buttonStyle(.plain)
    }

    private var strokeColor: Color {
        isSelected
            ? Color.accentColor
            : Color.secondary.opacity(SettingsLayoutConstants.IconGrid.unselectedStrokeOpacity)
    }

    private var strokeWidth: CGFloat {
        isSelected
            ? SettingsLayoutConstants.IconGrid.selectionStrokeWidth
            : SettingsLayoutConstants.IconGrid.unselectedStrokeWidth
    }
}

