import SwiftUI

struct CategoriesSettingsView: View {
    /// A day's worth of minutes. The limit is a budget for time tracked in one day, so a day is the
    /// most that can be spent against it and anything above is unreachable rather than merely
    /// generous. An upper bound is also required now the field is a `SteppedNumberField`, which
    /// steps within a range: without one, a held arrow would have nothing to stop at.
    static let maximumDailyLimitMinutes = 1440

    @ObservedObject var appState: AppState
    let loadCategories: () -> [CategoryRecord]
    let createCategory: (String) -> Int?
    let findCategory: (String) -> CategoryRecord?
    let findCategories: (String) -> [CategoryRecord]
    let updateCategoryColour: (Int, Int) -> Void
    let updateCategoryDailyLimit: (Int, Int) -> Void
    let updateCategoryActive: (Int, Bool) -> Bool
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
                    categories: CategoryEditRules.partitioned(categories).active,
                    emptyMessage: "No active categories.",
                    appState: appState,
                    actions: actions
                )
            }
            Section {
                CategoryCreateControl(
                    appState: appState,
                    createCategory: createCategory,
                    findCategories: findCategories,
                    // Patched in place rather than re-read, so the reinstated row moves from the
                    // Inactive section to the Active one straight away.
                    reactivate: { actions.setActive($0.id, true) },
                    // The new category's id is of no use here: this tab has no face in front
                    // of it to put the category on, unlike the Faces tab's create control.
                    onCreated: { _ in categories = loadCategories() }
                )
            }
            Section {
                CategorySection(
                    title: "Inactive",
                    isExpanded: $isInactiveExpanded,
                    categories: CategoryEditRules.partitioned(categories).inactive,
                    emptyMessage: "No inactive categories.",
                    isRetiredList: true,
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
                // Patched only if the write took. Reinstating can be refused when an active
                // category has taken the name since, and patching regardless would tick the box
                // over a row that is still retired.
                guard updateCategoryActive(categoryID, isActive) else { return false }
                patch(categoryID) { $0.with(isActive: isActive) }
                return true
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
        categories = CategoryEditRules.patching(categories, id: categoryID, transform)
    }
}

/// What a category row needs to read and change, bundled so it travels together down to the row.
struct CategoryRowActions {
    let setColour: (Int, Int) -> Void
    let setDailyLimit: (Int, Int) -> Void
    /// Returns whether the change was stored. `false` means the database refused it, which
    /// currently only happens when reinstating a category whose name an active one now holds.
    let setActive: (Int, Bool) -> Bool
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
    /// Whether this is the archive list, which is a different set of columns rather than the same
    /// set with one appended: no icon, colour or daily limit, and a last-used date instead. True
    /// for Inactive only. The rows work it out from `category.isActive` rather than being told, and
    /// the two always agree because `CategoryEditRules.partitioned` is what fills each list.
    var isRetiredList = false
    @ObservedObject var appState: AppState
    let actions: CategoryRowActions

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: SettingsLayoutConstants.CategoryList.rowSpacing) {
                if categories.isEmpty {
                    Text(emptyMessage)
                        .foregroundStyle(.secondary)
                } else {
                    CategoryColumnHeaderRow(isRetiredList: isRetiredList)
                    ForEach(categories) { category in
                        CategoryRow(
                            appState: appState,
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
        // Which section this is, in the one form accessibility will carry. A `DisclosureGroup`'s
        // label subtree is not surfaced at all -- a section exposes only its disclosure triangle,
        // which carries no name of its own -- so without this a test can address these sections by
        // position and never check that group 1 is still the Active one.
        //
        // `.accessibilityLabel` is the wrong tool and actively harmful here: it does not name the
        // triangle, it overwrites the label of every descendant. Measured 2026-08-10, all nine
        // static texts in this section came back reading "Inactive" instead of the category names
        // and dates -- a broken screen reader, and every assertion in `14b` gone. The same finding
        // as `TimeFlipSettingsView`'s Forget/Reset buttons on 2026-07-31: label never appears,
        // identifier does.
        .accessibilityIdentifier(title)
    }
}

/// Column labels above the category list, aligned to `CategoryRow`'s own column widths so each
/// label sits directly over its column -- no label over the icon column, since there's nothing
/// meaningful to caption there.
///
/// The two lists have different columns, so this draws two different headers rather than one with
/// an optional extra. See `CategoryRow` for why the archive drops three of them.
private struct CategoryColumnHeaderRow: View {
    let isRetiredList: Bool

    var body: some View {
        HStack(spacing: SettingsLayoutConstants.FaceList.rowSpacing) {
            if isRetiredList {
                Text("Active")
                    .frame(width: SettingsLayoutConstants.CategoryList.activeColumnWidth, alignment: .leading)
                Text("Name")
                    .frame(width: SettingsLayoutConstants.CategoryList.nameColumnWidth, alignment: .leading)
                Text(CategoryLastUsedText.columnTitle)
                    .fixedSize()
            } else {
                Color.clear
                    .frame(width: SettingsLayoutConstants.FaceList.iconSize, height: 1)
                Text("Name")
                    .frame(width: SettingsLayoutConstants.CategoryList.nameColumnWidth, alignment: .leading)
                Text("Colour")
                    .frame(width: SettingsLayoutConstants.CategoryList.colourColumnWidth, alignment: .leading)
                Text("Daily limit (0 = disabled)")
                    .frame(width: SettingsLayoutConstants.CategoryList.limitColumnWidth, alignment: .leading)
                Text("Active")
                    .frame(width: SettingsLayoutConstants.CategoryList.activeColumnWidth, alignment: .leading)
            }
            Spacer()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

private struct CategoryRow: View {
    /// Only for the daily-limit stepper's hold state, which lives on `AppState` so the window can
    /// cancel a hold it never saw released.
    @ObservedObject var appState: AppState
    let category: CategoryRecord
    let colourOptions: [ActivityColorOption]
    let iconOptions: [CategoryIconOption]
    let actions: CategoryRowActions
    @State private var isColorPickerPresented = false
    @State private var isIconPickerPresented = false
    @State private var isEditingName = false
    @State private var draftName = ""
    /// Which confirmation a Save raised, if any. Non-nil is what puts it on screen.
    @State private var renameConfirmation: CategoryRenameConfirmation?
    /// Set when the database refused to reinstate this row, which puts the explanation on screen.
    @State private var reinstateRefused = false
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

    /// The two lists draw different rows, so this picks between them rather than hiding columns out
    /// of one shared layout.
    var body: some View {
        HStack(spacing: SettingsLayoutConstants.FaceList.rowSpacing) {
            if category.isActive {
                activeRow
            } else {
                retiredRow
            }
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

    /// Everything a category you are still using needs: what it looks like on the cube, what it is
    /// called, and its budget.
    @ViewBuilder
    private var activeRow: some View {
        iconButton
        nameField
        colourSwatch
            .frame(width: SettingsLayoutConstants.CategoryList.colourColumnWidth, alignment: .leading)
        dailyLimitField
            .frame(width: SettingsLayoutConstants.CategoryList.limitColumnWidth, alignment: .leading)
        activeCheckbox
            .frame(width: SettingsLayoutConstants.CategoryList.activeColumnWidth, alignment: .leading)
    }

    /// A retired row is a narrower thing: the box that brings it back, its name, and when it last
    /// recorded time.
    ///
    /// The icon, colour and daily limit are gone rather than merely disabled. A retired category is
    /// kept only so historical `time_entry` rows still resolve, so those three are a record of what
    /// it was, and drawing them dead invited the reader to try. Removing them also keeps the archive
    /// narrower than the Active list, so the last-used column costs the window no width -- it is the
    /// widest section that sets it, and that is still the one you work in.
    ///
    /// The Active box leads rather than trails, because reinstating is the only thing this row does.
    /// In the Active list that box is the last column, the far end of a row full of settings; here
    /// there are no settings, so putting it first makes it the point of the row rather than
    /// something to read past.
    @ViewBuilder
    private var retiredRow: some View {
        activeCheckbox
            .frame(width: SettingsLayoutConstants.CategoryList.activeColumnWidth, alignment: .leading)
        nameField
        lastUsedLabel
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

    @ViewBuilder
    private func renameButtons(for confirmation: CategoryRenameConfirmation) -> some View {
        switch confirmation {
        case .plain(let newName):
            Button("OK") { commitRename(to: newName) }
            Button("Cancel", role: .cancel) { cancelRename() }
        case .activeCollision:
            Button("Ok I am an idiot that needs to open my eyes", role: .cancel) { cancelRename() }
        case .inactiveCollision(_, let newName):
            Button("Rename anyway") { commitRename(to: newName) }
            Button("Cancel", role: .cancel) { cancelRename() }
        }
    }

    /// Raises whatever `CategoryEditRules` says this name calls for. The tidying, the
    /// unchanged/empty cases and the collision branches all live there; what is left here is
    /// putting the alert up and logging what happened.
    private func requestRename() {
        switch CategoryEditRules.renameDecision(
            rawName: draftName,
            currentName: category.name,
            currentID: category.id,
            findCategory: actions.findCategory
        ) {
        case .ignore:
            cancelRename()
        case .confirm(let confirmation):
            if case .activeCollision(let existing, _) = confirmation {
                DeveloperMode.debugPrint(.field, "Rename collision: \"\(confirmation.attemptedName)\" matches category_id \(existing.id) (active=true)")
            }
            if case .inactiveCollision(let existing, _) = confirmation {
                DeveloperMode.debugPrint(.field, "Rename collision: \"\(confirmation.attemptedName)\" matches category_id \(existing.id) (active=false)")
            }
            renameConfirmation = confirmation
        }
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
                        size: SettingsLayoutConstants.FaceList.iconSize
                    )
                } else {
                    Image(systemName: "nosign")
                        .resizable()
                        .scaledToFit()
                        .foregroundStyle(.secondary)
                        .frame(
                            width: SettingsLayoutConstants.FaceList.iconSize,
                            height: SettingsLayoutConstants.FaceList.iconSize
                        )
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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

    /// Whole minutes per day, 0 = disabled. The same `SteppedNumberField` every other typeable
    /// value in the window uses, so this row's arrows accelerate and commit exactly as auto-pause
    /// does rather than being the one number on either tab that behaves differently.
    ///
    /// `holdKey` carries the category id: a single hold is live at a time across the whole window
    /// (`AppState.steppedFieldHoldKey`), so two rows sharing a key would have the second press read
    /// as the first still being down.
    private var dailyLimitField: some View {
        SteppedNumberField(
            appState: appState,
            holdKey: "category.dailyLimit.\(category.id)",
            value: category.dailyLimitMinutes,
            range: 0...CategoriesSettingsView.maximumDailyLimitMinutes,
            suffix: "min",
            fieldWidth: SettingsLayoutConstants.Stepper.fieldWidth,
            suffixWidth: SettingsLayoutConstants.Stepper.suffixWidth,
            onCommit: { applyDailyLimit(newValue: $0) }
        )
    }

    /// Unticking moves the row straight to the Inactive group, and ticking it there moves it back
    /// -- the list this row was built from is re-partitioned by the same edit that writes the
    /// change, so the row lands in the matching group on the next render.
    ///
    /// Ticking can be refused: only one *active* category may hold a name, so a retired row whose
    /// name an active one has taken since cannot come back under it. Nothing moves in that case and
    /// the alert says why, rather than the box appearing to tick and silently springing back.
    ///
    /// Unticking is barred outright while a locked face holds this category. Retiring takes the
    /// category off every face it is on, and a locked face is one the user has said keeps what it
    /// has, so the two instructions contradict each other and the app does not get to pick which
    /// wins. The user does, by unlocking the face on the Faces tab first. Disabled rather than
    /// refused with an alert: the box would otherwise offer an edit that can never be taken.
    ///
    /// Only *this* direction is barred. A retired category on a locked face -- which a database
    /// predating this rule can hold -- must still be reinstatable, and reinstating puts nothing on
    /// any face.
    /// When a retired category last recorded time, sitting under the "Last used" header to the right
    /// of its Active box.
    ///
    /// Nothing at all on an active row (`CategoryLastUsedText.label` returns nil), which is why only
    /// the Inactive list's header carries the caption. Secondary and small: it is context for a
    /// decision about reinstating, not a control, and it must not compete with the name at the other
    /// end of the row.
    @ViewBuilder
    private var lastUsedLabel: some View {
        if let text = CategoryLastUsedText.label(isActive: category.isActive, lastUsed: category.lastUsed) {
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize()
        }
    }

    private var activeCheckbox: some View {
        // The tooltip is on the container, outside `.disabled()`: a disabled control stops taking
        // mouse events, and a help tag it never sees is no use on the one row that needs one.
        HStack(spacing: 0) {
            Toggle("", isOn: Binding(
                get: { category.isActive },
                set: { newValue in
                    DeveloperMode.debugPrint(.click, "Button clicked: Category \"\(category.name)\" active -> \(newValue)")
                    guard actions.setActive(category.id, newValue) else {
                        DeveloperMode.debugPrint(.field, "Category \"\(category.name)\" could not be reinstated: the name is taken by an active category")
                        reinstateRefused = true
                        return
                    }
                }
            ))
            .toggleStyle(.checkbox)
            .labelsHidden()
            .disabled(category.isActive && !lockedFacesHoldingThis.isEmpty)
        }
        // The row gives no clue which face is in the way, so the tooltip names it.
        .help(lockedFaceHelp)
        .alert("That name is already in use", isPresented: $reinstateRefused) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("""
            An active category is already called "\(category.name)", so this one cannot be \
            reinstated under that name.

            Rename one of them first, then try again.
            """)
        }
    }

    /// The locked faces standing in the way of retiring this category, read live from `appState` so
    /// unlocking a face on the Faces tab re-enables the box here with no re-read.
    private var lockedFacesHoldingThis: [UInt8] {
        appState.lockedFacesHolding(categoryID: category.id)
    }

    /// Names the faces blocking the Active box, or `""` when nothing is -- SwiftUI draws no help tag
    /// for an empty string, so an ordinary row keeps its bare checkbox.
    private var lockedFaceHelp: String {
        let faces = lockedFacesHoldingThis
        guard category.isActive, !faces.isEmpty else { return "" }
        let list = faces.map(String.init).joined(separator: ", ")
        guard faces.count > 1 else {
            return "Face \(list) is locked to this category. Unlock it on the Faces tab to deactivate this category."
        }
        return "Faces \(list) are locked to this category. Unlock them on the Faces tab to deactivate this category."
    }

    private func applyDailyLimit(newValue: Int) {
        guard let clamped = CategoryEditRules.dailyLimitWrite(
            typed: newValue,
            current: category.dailyLimitMinutes
        ) else { return }
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
                    let newIconID = CategoryEditRules.iconSelection(
                        clicked: option.iconId,
                        selected: selectedIconID
                    )
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

