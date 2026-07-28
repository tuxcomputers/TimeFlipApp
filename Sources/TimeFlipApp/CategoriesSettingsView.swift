import SwiftUI

struct CategoriesSettingsView: View {
    @ObservedObject var appState: AppState
    let loadCategories: () -> [CategoryRecord]
    let createCategory: (String) -> Void
    let findCategory: (String) -> CategoryRecord?
    let updateCategoryColour: (Int, Int) -> Void
    let updateCategoryDailyLimit: (Int, Int) -> Void
    let updateCategoryActive: (Int, Bool) -> Void
    let updateCategoryName: (Int, String) -> Void
    let updateCategoryIcon: (Int, Int) -> Void
    @State private var categories: [CategoryRecord] = []
    // Active is the section you actually work in, so it starts open; Inactive is the archive you
    // only occasionally go looking in, so it starts folded away.
    @State private var isActiveExpanded = true
    @State private var isInactiveExpanded = false

    var body: some View {
        Form {
            // Each group gets its own Section so the grouped form draws them as separate boxes,
            // with the create control sitting in the gap between rather than inside either list.
            Section {
                CategorySection(
                    title: "Active",
                    isExpanded: $isActiveExpanded,
                    categories: categories.filter(\.isActive),
                    emptyMessage: "No active categories.",
                    appState: appState,
                    actions: actions
                )
            }
            Section {
                CategoryCreateControl(
                    appState: appState,
                    createCategory: createCategory,
                    findCategory: findCategory,
                    // Patched in place rather than re-read, so the reinstated row moves from the
                    // Inactive section to the Active one straight away.
                    reactivate: { actions.setActive($0.id, true) },
                    onCreated: { categories = loadCategories() }
                )
            }
            Section {
                CategorySection(
                    title: "Inactive",
                    isExpanded: $isInactiveExpanded,
                    categories: categories.filter { !$0.isActive },
                    emptyMessage: "No inactive categories.",
                    appState: appState,
                    actions: actions
                )
            }
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
            },
            setName: { categoryID, name in
                updateCategoryName(categoryID, name)
                patch(categoryID) { $0.with(name: name) }
            },
            findCategory: findCategory
        )
    }

    private func patch(_ categoryID: Int, _ transform: (CategoryRecord) -> CategoryRecord) {
        guard let index = categories.firstIndex(where: { $0.id == categoryID }) else { return }
        categories[index] = transform(categories[index])
    }
}

/// What a category row needs to read and change, bundled so it travels together down to the row.
struct CategoryRowActions {
    let setColour: (Int, Int) -> Void
    let setDailyLimit: (Int, Int) -> Void
    let setActive: (Int, Bool) -> Void
    let setIcon: (Int, Int) -> Void
    let setName: (Int, String) -> Void
    /// Used by the rename flow to spot a name that is already taken, the same check Save runs.
    let findCategory: (String) -> CategoryRecord?
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
                            iconOptions: appState.iconOptions,
                            actions: actions
                        )
                    }
                }
            }
            .padding(.vertical, SettingsLayoutConstants.CategoryList.sectionVerticalPadding)
        } label: {
            DisclosureRowLabel(title, logName: "\(title) categories", isExpanded: isExpanded) {
                isExpanded.toggle()
            }
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
    let iconOptions: [CategoryIconOption]
    let actions: CategoryRowActions
    @State private var isColorPickerPresented = false
    @State private var isIconPickerPresented = false
    @State private var isEditingName = false
    @State private var draftName = ""
    /// Which confirmation a Save raised, if any. Non-nil is what puts it on screen.
    @State private var renameConfirmation: RenameConfirmation?
    @FocusState private var isNameFieldFocused: Bool

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
            nameField
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
        .alert(
            renameConfirmation?.title ?? "",
            isPresented: Binding(
                get: { renameConfirmation != nil },
                set: { if !$0 { renameConfirmation = nil } }
            ),
            presenting: renameConfirmation
        ) { confirmation in
            renameButtons(for: confirmation)
        } message: { confirmation in
            Text(confirmation.message(currentName: category.name))
        }
    }

    /// Read-only until Edit is chosen from its right-click menu, then an inline field. Enter
    /// raises the confirmation and the name only changes once that is accepted; Escape abandons
    /// the edit outright.
    @ViewBuilder
    private var nameField: some View {
        if isEditingName {
            TextField("", text: $draftName)
                .textFieldStyle(.roundedBorder)
                .labelsHidden()
                .focused($isNameFieldFocused)
                .onAppear {
                    // Deferred a runloop turn: at onAppear the field is not yet in the window's
                    // responder chain, so focusing it synchronously is dropped.
                    DispatchQueue.main.async { isNameFieldFocused = true }
                }
                .onSubmit(requestRename)
                // Escape backs out without confirming anything. Without it the only way out of
                // edit mode is Enter and then Cancel, so opening Edit by mistake costs a round
                // trip through a dialog.
                .onExitCommand(perform: cancelRename)
                .frame(width: SettingsLayoutConstants.CategoryList.nameColumnWidth, alignment: .leading)
        } else {
            Text(category.name)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: SettingsLayoutConstants.CategoryList.nameColumnWidth, alignment: .leading)
                // Without this the menu only opens over the glyphs themselves, not the rest of the
                // fixed-width column, which is a small target on a short name.
                .contentShape(Rectangle())
                .contextMenu {
                    Button("Edit") {
                        DeveloperMode.debugPrint(.click, "Button clicked: Edit category name \"\(category.name)\"")
                        draftName = category.name
                        isEditingName = true
                    }
                }
        }
    }

    /// What a Save raised. Mirrors the create flow's collision handling: a name already in use by
    /// an active category is a dead end, an inactive one is a "are you sure" -- with the plain
    /// history warning when the name is free.
    private enum RenameConfirmation: Identifiable {
        case plain(newName: String)
        case activeCollision(existingName: String)
        case inactiveCollision(newName: String)

        var id: String {
            switch self {
            case .plain(let name): return "plain:\(name)"
            case .activeCollision(let name): return "active:\(name)"
            case .inactiveCollision(let name): return "inactive:\(name)"
            }
        }

        var title: String {
            switch self {
            case .plain: return "Rename this category?"
            case .activeCollision, .inactiveCollision: return "That category already exists"
            }
        }

        /// The history caveat rides along with the inactive case rather than following it in a
        /// second dialog: both facts are about the same single decision, and stacking two alerts
        /// to agree to one rename is worse than one alert that says both.
        func message(currentName: String) -> String {
            switch self {
            case .plain(let newName):
                return historyWarning(currentName: currentName, newName: newName)
            case .activeCollision(let existingName):
                return """
                "\(existingName)" is already in the Active list, so this name is taken.
                """
            case .inactiveCollision(let newName):
                return """
                "\(newName)" already exists as an inactive category. Renaming to it leaves two \
                categories with that name, and sorting them apart in reports later is on you. Do \
                you really want to do this?

                \(historyWarning(currentName: currentName, newName: newName))
                """
            }
        }

        private func historyWarning(currentName: String, newName: String) -> String {
            """
            "\(currentName)" keeps all of its history -- nothing recorded against it is lost.

            But everything links to this category by id rather than by name, so reports covering \
            time before the rename will show "\(newName)" too, not the name that was in use then.
            """
        }
    }

    @ViewBuilder
    private func renameButtons(for confirmation: RenameConfirmation) -> some View {
        switch confirmation {
        case .plain(let newName):
            Button("OK") { commitRename(to: newName) }
            Button("Cancel", role: .cancel) { cancelRename() }
        case .activeCollision:
            Button("Ok I am an idiot that needs to open my eyes", role: .cancel) { cancelRename() }
        case .inactiveCollision(let newName):
            Button("Rename anyway") { commitRename(to: newName) }
            Button("Cancel", role: .cancel) { cancelRename() }
        }
    }

    /// Tidied the same way a newly created name is, so a rename cannot introduce the padding or
    /// doubled spaces that creating would have collapsed. An unchanged or empty name just leaves
    /// edit mode -- there is nothing to confirm.
    ///
    /// The taken-name check skips a hit on this same category: `findCategory` matches
    /// `COLLATE NOCASE`, so "meeting" -> "Meeting" on the row being renamed finds itself, and
    /// correcting a name's capitalisation is not a collision.
    private func requestRename() {
        let name = ActivityLibrary.normalizeCategoryName(draftName)
        guard !name.isEmpty, name != category.name else {
            cancelRename()
            return
        }
        if let existing = actions.findCategory(name), existing.id != category.id {
            DeveloperMode.debugPrint(.field, "Rename collision: \"\(name)\" matches category_id \(existing.id) (active=\(existing.isActive))")
            renameConfirmation = existing.isActive
                ? .activeCollision(existingName: existing.name)
                : .inactiveCollision(newName: name)
            return
        }
        renameConfirmation = .plain(newName: name)
    }

    private func commitRename(to newName: String) {
        DeveloperMode.debugPrint(.click, "Button clicked: Confirm rename \"\(category.name)\" -> \"\(newName)\"")
        actions.setName(category.id, newName)
        cancelRename()
    }

    private func cancelRename() {
        renameConfirmation = nil
        isEditingName = false
        isNameFieldFocused = false
        draftName = ""
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
                colourOptions: colourOptions,
                selectedColourID: category.colourID
            ) { colourID in
                actions.setColour(category.id, colourID)
                isColorPickerPresented = false
            }
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
        // The first cell takes keyboard focus when the popover opens, and its focus ring reads as
        // a second selection sitting next to the real one. Disabling the effect leaves the accent
        // stroke as the only blue in the grid, while keeping the cells keyboard-reachable.
        .focusEffectDisabled()
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

