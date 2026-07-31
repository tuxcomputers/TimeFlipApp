import AppKit
import SwiftUI

struct SettingsRootView: View {
    @ObservedObject var appState: AppState
    @ObservedObject var authManager: GoogleAuthManager
    let integrationCoordinator: GoogleIntegrationCoordinator
    let loadCategories: () -> [CategoryRecord]
    /// Inserts the category and returns its new `category_id`, or `nil` if the insert failed.
    let createCategory: (String) -> Int?
    let findCategory: (String) -> CategoryRecord?
    let updateCategoryColour: (Int, Int) -> Void
    let updateCategoryDailyLimit: (Int, Int) -> Void
    let updateCategoryActive: (Int, Bool) -> Bool
    let updateCategoryName: (Int, String) -> Void
    let updateCategoryIcon: (Int, Int) -> Void
    /// Assigns a category to a physical face: `(face_id, category_id)`.
    let assignCategoryToFace: (UInt8, Int) -> Void
    /// Locks or unlocks a physical face: `(face_id, locked)`.
    let setFaceLocked: (UInt8, Bool) -> Void
    @State private var selectedTab: SettingsTab = .faces
    let onMinimumContentHeightChange: (CGFloat) -> Void
    let onClose: () -> Void

    init(
        appState: AppState,
        authManager: GoogleAuthManager,
        integrationCoordinator: GoogleIntegrationCoordinator,
        loadCategories: @escaping () -> [CategoryRecord],
        createCategory: @escaping (String) -> Int?,
        findCategory: @escaping (String) -> CategoryRecord?,
        updateCategoryColour: @escaping (Int, Int) -> Void,
        updateCategoryDailyLimit: @escaping (Int, Int) -> Void,
        updateCategoryActive: @escaping (Int, Bool) -> Bool,
        updateCategoryName: @escaping (Int, String) -> Void,
        updateCategoryIcon: @escaping (Int, Int) -> Void,
        assignCategoryToFace: @escaping (UInt8, Int) -> Void,
        setFaceLocked: @escaping (UInt8, Bool) -> Void,
        onClose: @escaping () -> Void = {},
        onMinimumContentHeightChange: @escaping (CGFloat) -> Void = { _ in }
    ) {
        self.appState = appState
        self.authManager = authManager
        self.integrationCoordinator = integrationCoordinator
        self.loadCategories = loadCategories
        self.createCategory = createCategory
        self.findCategory = findCategory
        self.updateCategoryColour = updateCategoryColour
        self.updateCategoryDailyLimit = updateCategoryDailyLimit
        self.updateCategoryActive = updateCategoryActive
        self.updateCategoryName = updateCategoryName
        self.updateCategoryIcon = updateCategoryIcon
        self.assignCategoryToFace = assignCategoryToFace
        self.setFaceLocked = setFaceLocked
        self.onClose = onClose
        self.onMinimumContentHeightChange = onMinimumContentHeightChange
    }

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $selectedTab) {
                TimeFlipSettingsView(appState: appState)
                    .tabItem {
                        Text("Device")
                    }
                    .tag(SettingsTab.timeflip)
                CategoriesSettingsView(
                    appState: appState,
                    loadCategories: loadCategories,
                    createCategory: createCategory,
                    findCategory: findCategory,
                    updateCategoryColour: updateCategoryColour,
                    updateCategoryDailyLimit: updateCategoryDailyLimit,
                    updateCategoryActive: updateCategoryActive,
                    updateCategoryName: updateCategoryName,
                    updateCategoryIcon: updateCategoryIcon
                )
                    .tabItem {
                        Text("Categories")
                    }
                    .tag(SettingsTab.categories)
                PaneSetupView(
                    appState: appState,
                    loadCategories: loadCategories,
                    createCategory: createCategory,
                    findCategory: findCategory,
                    updateCategoryActive: updateCategoryActive,
                    assignCategoryToFace: assignCategoryToFace,
                    setFaceLocked: setFaceLocked
                )
                    .tabItem {
                        Text("Faces")
                    }
                    .tag(SettingsTab.faces)
                ReportSettingsView(
                    appState: appState,
                    authManager: authManager,
                    integrationCoordinator: integrationCoordinator
                )
                    .tabItem {
                        Text("App")
                    }
                    .tag(SettingsTab.report)
            }
            .onChange(of: appState.pendingSettingsTab) { _, newValue in
                guard let newValue else { return }
                selectedTab = newValue
                appState.pendingSettingsTab = nil
            }
            .onChange(of: selectedTab) { _, newValue in
                DeveloperMode.debugPrint(.tab, "Tab switched to: \(newValue.debugName)")
            }
            .onPreferenceChange(FacesColumnHeightPreferenceKey.self) { height in
                guard height > 0 else { return }
                onMinimumContentHeightChange(height)
            }
            HStack {
                Spacer()
                Button("Close") {
                    DeveloperMode.debugPrint(.click, "Button clicked: Close (Settings window)")
                    onClose()
                }
                // Given up while a category name is being typed, so Escape cancels that field
                // instead: a key equivalent is dispatched before the focused field sees the key, so
                // the field cannot win this any other way.
                .keyboardShortcut(appState.isNamingCategory ? nil : .cancelAction)
                .padding([.horizontal, .bottom], SettingsLayoutConstants.Pane.sectionSpacing)
                .padding(.top, SettingsLayoutConstants.Pane.sectionSpacing / 2)
            }
        }
        .frame(minWidth: SettingsLayoutConstants.minimumWindowWidth)
    }
}

enum SettingsTab: Hashable {
    case timeflip
    case categories
    case faces
    case report

    /// Matches the tab's visible title, for the `tab` debug log (see SettingsRootView).
    var debugName: String {
        switch self {
        case .timeflip: return "Device"
        case .categories: return "Categories"
        case .faces: return "Faces"
        case .report: return "App"
        }
    }
}

private struct PaneSetupView: View {
    @ObservedObject var appState: AppState
    let loadCategories: () -> [CategoryRecord]
    let createCategory: (String) -> Int?
    let findCategory: (String) -> CategoryRecord?
    let updateCategoryActive: (Int, Bool) -> Bool
    let assignCategoryToFace: (UInt8, Int) -> Void
    let setFaceLocked: (UInt8, Bool) -> Void
    /// Loaded once when the tab appears, the same way the Categories tab reads its own list.
    @State private var categories: [CategoryRecord] = []

    var body: some View {
        // swiftlint:disable closure_body_length
        GeometryReader { proxy in
            let spacing = SettingsLayoutConstants.Pane.columnSpacing
            let horizontalPadding = SettingsLayoutConstants.Pane.horizontalPadding
            let verticalPadding = SettingsLayoutConstants.Pane.verticalPadding
            let contentWidth = max(0, proxy.size.width - (horizontalPadding * 2))
            let total = max(0, contentWidth - spacing)
            let leftWidth = total * SettingsLayoutConstants.Pane.leftColumnRatio
            let rightWidth = total * SettingsLayoutConstants.Pane.rightColumnRatio

            HStack(alignment: .top, spacing: spacing) {
                VStack(alignment: .leading, spacing: SettingsLayoutConstants.Pane.sectionSpacing) {
                    Text("Top face")
                        .font(.headline)

                    if let index = appState.mappingIndex(for: appState.currentFaceID) {
                        let binding = Binding(
                            get: { appState.faceMappings[index] },
                            set: { appState.updateMapping($0) }
                        )
                        TopFaceEditor(
                            mapping: binding,
                            litColour: appState.deviceBodyColour(for: appState.currentFaceID),
                            lineColour: appState.deviceLineColour(for: appState.currentFaceID),
                            iconName: appState.categoryActivity(for: appState.currentFaceID)?.iconName,
                            categoryName: appState.categoryActivity(for: appState.currentFaceID)?.name,
                            isLocked: appState.isFaceLocked(appState.currentFaceID),
                            onToggleLock: {
                                let faceID = appState.currentFaceID
                                let locked = !appState.isFaceLocked(faceID)
                                DeveloperMode.debugPrint(.click, "Button clicked: Face \(faceID) lock -> \(locked ? "locked" : "unlocked")")
                                setFaceLocked(faceID, locked)
                            }
                        )
                    } else {
                        Text("Flip the device to pick a face.")
                            .foregroundStyle(.secondary)
                            .padding(.vertical, SettingsLayoutConstants.Pane.emptyStateVerticalPadding)
                    }
                }
                .frame(width: leftWidth, alignment: .topLeading)
                .frame(maxHeight: .infinity, alignment: .topLeading)

                VStack(alignment: .leading, spacing: SettingsLayoutConstants.Pane.sectionSpacing) {
                    Text("Categories")
                        .font(.headline)

                    CategoryAssignmentList(
                        categories: categories.filter(\.isActive),
                        iconOptions: appState.iconOptions,
                        colourOptions: appState.colourOptions,
                        // A locked face keeps the category it has, so there is nothing here to
                        // click. The write refuses a locked face too, in case this ever gets past.
                        canAssign: canAssignToFaceOnShow,
                        onSelect: { assignCategoryToFace(appState.currentFaceID, $0) }
                    )

                    CategoryCreateControl(
                        appState: appState,
                        createCategory: createCategory,
                        findCategory: findCategory,
                        // Re-read rather than patched: this list only shows active categories, so a
                        // reinstated one has to appear in it.
                        reactivate: { category in
                            // Nothing to re-read or assign if the reinstate was refused: the
                            // category is still retired, so it would not appear in this list and
                            // must not land on the face either.
                            guard updateCategoryActive(category.id, true) else { return false }
                            categories = loadCategories()
                            assignToFaceOnShow(category.id)
                            return true
                        },
                        onCreated: { newCategoryID in
                            categories = loadCategories()
                            guard let newCategoryID else { return }
                            assignToFaceOnShow(newCategoryID)
                        }
                    )
                }
                .frame(width: rightWidth, alignment: .leading)
                .background(
                    GeometryReader { columnProxy in
                        Color.clear.preference(
                            key: FacesColumnHeightPreferenceKey.self,
                            value: columnProxy.size.height + (verticalPadding * 2)
                        )
                    }
                )
            }
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, verticalPadding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .onAppear { categories = loadCategories() }
        }
        // swiftlint:enable closure_body_length
    }

    /// Whether the face on show will take a category: there has to be a real face up, and a locked
    /// face keeps the one it already has. Read by the assignment list to decide whether its rows are
    /// live, and by `assignToFaceOnShow` for the same question, so the two cannot disagree.
    private var canAssignToFaceOnShow: Bool {
        TimeFlipConstants.isValidFaceID(appState.currentFaceID)
            && !appState.isFaceLocked(appState.currentFaceID)
    }

    /// Puts a just-created category straight onto the face on show. Creating a category on *this*
    /// tab is done while looking at a particular face, and that face is the reason it is being
    /// created, so it lands there rather than leaving the user to find the new row in the list below
    /// and click it. The Categories tab, which has no face in front of it, creates without
    /// assigning -- which is why this lives here and not in `CategoryCreateControl`.
    ///
    /// It overwrites whatever the face held: the face was unlocked and the user asked for a new
    /// category while on it, which is the same instruction as clicking a row in the list.
    ///
    /// Does nothing when the face won't take it -- no face reported yet, or a locked one. Neither
    /// needs saying twice: the list beside this is already visibly dead and the lock already reads
    /// red, and the write itself refuses a locked face anyway.
    private func assignToFaceOnShow(_ categoryID: Int) {
        let faceID = appState.currentFaceID
        guard canAssignToFaceOnShow else {
            DeveloperMode.debugPrint(.click, "New category \(categoryID) left unassigned: face \(faceID) is \(appState.isFaceLocked(faceID) ? "locked" : "not a face")")
            return
        }
        DeveloperMode.debugPrint(.click, "New category \(categoryID) assigned to the top face \(faceID)")
        assignCategoryToFace(faceID, categoryID)
    }
}

private struct TopFaceEditor: View {
    @Binding var mapping: FaceMapping
    /// The colour to light the device in: the colour of the category assigned to this face, or
    /// white when it has none (see `AppState.deviceBodyColour`).
    let litColour: Color
    /// The colour of the device's inner lines and centre icon (see `AppState.deviceLineColour`).
    let lineColour: Color
    /// The assigned category's icon, or `nil` when there isn't one to draw.
    let iconName: String?
    /// The assigned category's name, shown under the device.
    let categoryName: String?
    let isLocked: Bool
    let onToggleLock: () -> Void

    var body: some View {
        VStack(spacing: SettingsLayoutConstants.Pane.sectionSpacing) {
            // DeviceFaceView squares itself off, so the name sits directly under the device rather
            // than being pushed to the bottom of a tall column.
            DeviceFaceView(litColour: litColour, lineColour: lineColour, iconName: iconName)
                .overlay(alignment: .topLeading) {
                    FaceLockToggle(isLocked: isLocked, action: onToggleLock)
                }

            Text(categoryName ?? "")
                .font(.system(size: SettingsLayoutConstants.DeviceFace.nameFontSize, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(SettingsLayoutConstants.DeviceFace.nameMinimumScale)
                .frame(maxWidth: .infinity, alignment: .center)

            Spacer(minLength: 0)
        }
    }
}

/// Locks or unlocks the face on show, sitting in the corner of the device graphic.
///
/// A locked face keeps the category it has: the category list stops offering assignments while it
/// is locked, so this is what a user reaches for before, and after, pinning a face they mean to
/// keep -- Break and Meeting being the cases it exists for.
private struct FaceLockToggle: View {
    let isLocked: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            // Sized by font rather than by .resizable().scaledToFit(). Scaling to fit forces
            // both glyphs' bounding boxes into the same square, and the open lock's box is the
            // wider of the two because its shackle swings out, so its body came out smaller and
            // the lock appeared to change size as it toggled. At a given font size the two are
            // drawn to matching metrics, and anchoring the frame to the body's own corner keeps
            // it put while only the shackle moves.
            Image(systemName: isLocked ? "lock.fill" : "lock.open.fill")
                .font(.system(size: SettingsLayoutConstants.DeviceFace.lockSize))
                .frame(
                    width: SettingsLayoutConstants.DeviceFace.lockSize,
                    height: SettingsLayoutConstants.DeviceFace.lockSize,
                    alignment: .bottomLeading
                )
                // Red for locked, green for unlocked: the colour says whether the face will
                // accept a new category, matching the category list going dead beside it.
                .foregroundStyle(isLocked ? Color.red : Color.green)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Without this the button wears a focus ring the moment the tab takes focus, which reads
        // as a highlight around the lock rather than as keyboard focus. Same treatment as the
        // category list beside it.
        .focusEffectDisabled()
        .help(isLocked ? "Unlock this face so its category can be changed" : "Lock this face to keep its category")
        .accessibilityLabel(isLocked ? "Unlock face" : "Lock face")
    }
}

struct ActivityIconView: View {
    let iconName: String
    let tint: Color
    let size: CGFloat

    var body: some View {
        if let image = ActivityIconLoader.image(named: iconName, pointSize: size) {
            Image(nsImage: image)
                .resizable()
                .renderingMode(.template)
                .foregroundStyle(tint)
                .frame(width: size, height: size)
        } else {
            Image(systemName: "square.dashed")
                .resizable()
                .foregroundStyle(.secondary)
                .frame(width: size, height: size)
        }
    }
}

/// The device seen from directly above, lit in a single colour.
///
/// The hardware lights its whole body one colour for whichever face is upward -- it can't light
/// faces individually -- so this draws every face in `litColour` and keeps the artwork's own black
/// edges, which is why it deliberately skips the `.template` rendering `ActivityIconView` uses.
///
/// Squared off by aspect ratio and left to take whatever size it is given. It deliberately does
/// **not** measure the space it is offered to decide its own size: the artwork is a vector, and an
/// `NSImage` backed by one re-renders at whatever size it is drawn, so a fixed render size stays
/// crisp at any scale. Sizing off a `GeometryReader` here instead would make this view's size
/// depend on the height available to it, and the settings window already drives its own minimum
/// height from a measured column -- the two together form a layout feedback loop.
struct DeviceFaceView: View {
    let litColour: Color
    /// The colour of the inner lines and the centre icon. The outer outline is not drawn in this
    /// and stays black, so the device's shape reads against the window whatever it is lit in.
    let lineColour: Color
    /// The icon of the category assigned to this face, drawn on the centre face. `nil` when the
    /// face has no category, or its category has no icon.
    let iconName: String?

    var body: some View {
        device
            .aspectRatio(1, contentMode: .fit)
            // An overlay is sized by what it covers, so reading the geometry here scales the icon
            // to the device without the icon's size feeding back into the layout.
            .overlay {
                GeometryReader { proxy in
                    // The centre face is centred on the artwork, so centring the icon in the same
                    // frame puts it on that face without needing the pentagon's corners.
                    if let iconName {
                        ActivityIconView(
                            iconName: iconName,
                            tint: lineColour,
                            size: proxy.size.width * SettingsLayoutConstants.DeviceFace.centreIconScale
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    }
                }
            }
    }

    @ViewBuilder
    private var device: some View {
        if let image = ActivityIconLoader.colouredImage(
            named: "ic_timeflip2",
            pointSize: SettingsLayoutConstants.DeviceFace.renderPointSize,
            fill: NSColor(litColour),
            ink: NSColor(lineColour)
        ) {
            Image(nsImage: image)
                .resizable()
        } else {
            Image(systemName: "square.dashed")
                .resizable()
                .foregroundStyle(.secondary)
        }
    }
}

private struct IconGridPicker: View {
    @Binding var selection: String
    let tint: Color

    private let columns = [
        GridItem(
            .adaptive(
                minimum: SettingsLayoutConstants.IconGrid.minIconSize,
                maximum: SettingsLayoutConstants.IconGrid.maxIconSize
            ),
            spacing: SettingsLayoutConstants.IconGrid.columnSpacing
        )
    ]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: SettingsLayoutConstants.IconGrid.columnSpacing) {
                IconGridCell(
                    iconName: "",
                    isSelected: selection.isEmpty,
                    tint: tint
                ) {
                    DeveloperMode.debugPrint(.click, "Button clicked: Icon grid cell (none)")
                    selection = ""
                }

                ForEach(ActivityLibrary.iconOptions) { option in
                    IconGridCell(
                        iconName: option.iconName,
                        isSelected: selection == option.iconName,
                        tint: tint
                    ) {
                        DeveloperMode.debugPrint(.click, "Button clicked: Icon grid cell (\(option.iconName))")
                        selection = option.iconName
                    }
                }
            }
            .padding(.vertical, SettingsLayoutConstants.IconGrid.gridVerticalPadding)
        }
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .layoutPriority(1)
    }
}

private struct IconGridCell: View {
    let iconName: String
    let isSelected: Bool
    let tint: Color
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

                if iconName.isEmpty {
                    Image(systemName: "nosign")
                        .resizable()
                        .scaledToFit()
                        .foregroundStyle(.secondary)
                        .padding(SettingsLayoutConstants.IconGrid.cellPadding)
                } else if let image = ActivityIconLoader.image(
                    named: iconName,
                    pointSize: SettingsLayoutConstants.IconGrid.iconPointSize
                ) {
                    Image(nsImage: image)
                        .resizable()
                        .renderingMode(.template)
                        .foregroundStyle(tint)
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
            ? tint
            : Color.secondary.opacity(SettingsLayoutConstants.IconGrid.unselectedStrokeOpacity)
    }

    private var strokeWidth: CGFloat {
        isSelected
            ? SettingsLayoutConstants.IconGrid.selectionStrokeWidth
            : SettingsLayoutConstants.IconGrid.unselectedStrokeWidth
    }
}

/// The colour picker, built like `CategoryIconGrid`: a list of the real colours with no "None"
/// entry of its own. Clicking the selected colour clears it, picking `colour_id` 0 -- so the same
/// click both sets and unsets, and a dedicated None row would be a second way to do the same
/// thing.
struct ColorOptionList: View {
    let colourOptions: [ActivityColorOption]
    let selectedColourID: Int
    /// Receives the chosen `colour_id`, or 0 when the selected colour was clicked to clear it.
    let onPick: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(colourOptions) { option in
                let isSelected = option.colourId == selectedColourID
                ColorOptionRow(name: option.name, swatchColor: option.color, isSelected: isSelected) {
                    // Re-clicking the selected colour clears it; anything else selects it.
                    let newColourID = isSelected ? 0 : option.colourId
                    DeveloperMode.debugPrint(.click, "Button clicked: Color option \"\(option.name)\" -> colour_id \(newColourID)")
                    onPick(newColourID)
                }
            }
        }
        .padding(SettingsLayoutConstants.ColorPicker.listPadding)
        // Same as the icon grid: the first row takes keyboard focus when the popover opens, and
        // its focus ring reads as a selection. The checkmark is what marks the current colour.
        .focusEffectDisabled()
    }
}

private struct ColorOptionRow: View {
    let name: String
    let swatchColor: Color
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: SettingsLayoutConstants.ColorPicker.rowSpacing) {
                RoundedRectangle(cornerRadius: SettingsLayoutConstants.ColorPicker.rowSwatchCornerRadius)
                    .fill(swatchColor)
                    .frame(
                        width: SettingsLayoutConstants.ColorPicker.rowSwatchSize,
                        height: SettingsLayoutConstants.ColorPicker.rowSwatchSize
                    )
                Text(name)
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, SettingsLayoutConstants.ColorPicker.rowVerticalPadding)
            .padding(.horizontal, SettingsLayoutConstants.ColorPicker.rowHorizontalPadding)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// The categories a face can be assigned, listed on the Faces tab beside the device.
///
/// Only active categories appear: a retired one still has to resolve for historical `time_entry`
/// rows, but offering it for a new assignment is exactly what retiring it was meant to stop.
private struct CategoryAssignmentList: View {
    let categories: [CategoryRecord]
    let iconOptions: [CategoryIconOption]
    let colourOptions: [ActivityColorOption]
    /// `false` until the device has reported which face is up, since there's no face to assign to
    /// until then.
    let canAssign: Bool
    let onSelect: (Int) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ForEach(categories) { category in
                let colour = colourOptions.first { $0.colourId == category.colourID }
                CategoryAssignmentRow(
                    category: category,
                    iconName: iconOptions.first { $0.iconId == category.iconID }?.iconName,
                    colour: colour?.color,
                    // Same flag the drawn device reads, for the same reason: the icon sits on the
                    // category's colour here too, so a dark one swallows a black glyph.
                    iconColour: (colour?.usesWhiteLines ?? false) ? .white : .black,
                    onSelect: { onSelect(category.id) }
                )
                .disabled(!canAssign)
                if category.id != categories.last?.id {
                    Divider()
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: SettingsLayoutConstants.FaceList.cornerRadius)
                .fill(Color(NSColor.textBackgroundColor))
        )
        // The first row takes keyboard focus when the tab appears, and its focus ring reads as a
        // selection, as if that category were already the assigned one. Same reason the Categories
        // tab's icon grid disables the effect. The rows stay keyboard-reachable either way.
        .focusEffectDisabled()
    }
}

private struct CategoryAssignmentRow: View {
    let category: CategoryRecord
    /// `nil` for the None icon (`icon_id` 0), a sentinel rather than a bundled asset.
    let iconName: String?
    /// `nil` for the None colour (`colour_id` 0), which has no hex of its own.
    let colour: Color?
    /// The icon's own colour, white on a colour dark enough to swallow a black glyph.
    let iconColour: Color
    let onSelect: () -> Void

    var body: some View {
        Button(action: {
            DeveloperMode.debugPrint(.click, "Button clicked: Assign category \"\(category.name)\" to the top face")
            onSelect()
        }, label: { rowContent })
        .buttonStyle(.plain)
    }

    private var rowContent: some View {
        HStack(spacing: SettingsLayoutConstants.FaceList.rowSpacing) {
            // A category with no icon still fills the slot, with a hollow black square -- the same
            // way the Categories tab draws a category with no colour -- so it reads as "nothing
            // set" rather than as a gap, and every name in the list lines up either way.
            Group {
                if let iconName {
                    ZStack {
                        RoundedRectangle(
                            cornerRadius: SettingsLayoutConstants.FaceList.iconBackgroundCornerRadius
                        )
                        .fill(colour ?? Color(NSColor.controlBackgroundColor))
                        ActivityIconView(
                            iconName: iconName,
                            tint: iconColour,
                            size: SettingsLayoutConstants.FaceList.iconSize
                        )
                    }
                } else {
                    RoundedRectangle(
                        cornerRadius: SettingsLayoutConstants.FaceList.iconBackgroundCornerRadius
                    )
                    .stroke(Color.black)
                }
            }
            .frame(
                width: SettingsLayoutConstants.FaceList.iconBackgroundSize,
                height: SettingsLayoutConstants.FaceList.iconBackgroundSize
            )

            Text(category.name)

            Spacer()
        }
        .frame(height: SettingsLayoutConstants.faceRowHeight)
        .padding(.horizontal, SettingsLayoutConstants.FaceList.horizontalPadding)
        // Without this the row only responds to clicks that land on the icon or the text, not the
        // gap between them or the empty space the Spacer leaves to the right.
        .contentShape(Rectangle())
    }
}

private struct FaceMappingList: View {
    let mappings: [FaceMapping]
    let currentFaceID: UInt8
    let tint: (UInt8) -> Color

    var body: some View {
        VStack(spacing: 0) {
            ForEach(mappings) { mapping in
                FaceMappingRow(
                    mapping: mapping,
                    tint: tint(mapping.faceID),
                    isSelected: mapping.faceID == currentFaceID
                )
                if mapping.id != mappings.last?.id {
                    Divider()
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: SettingsLayoutConstants.FaceList.cornerRadius)
                .fill(Color(NSColor.textBackgroundColor))
        )
    }
}

private struct FaceMappingRow: View {
    let mapping: FaceMapping
    let tint: Color
    let isSelected: Bool

    var body: some View {
        HStack(spacing: SettingsLayoutConstants.FaceList.rowSpacing) {
            ActivityIconView(
                iconName: mapping.iconName,
                tint: tint,
                size: SettingsLayoutConstants.FaceList.iconSize
            )

            Text(mapping.displayName)
                .foregroundStyle(mapping.isAssigned ? .primary : .secondary)

            Spacer()
        }
        .frame(height: SettingsLayoutConstants.faceRowHeight)
        .padding(.horizontal, SettingsLayoutConstants.FaceList.horizontalPadding)
        .background(
            isSelected
            ? Color.accentColor.opacity(SettingsLayoutConstants.FaceList.selectionOpacity)
            : Color.clear
        )
    }
}

private struct FacesColumnHeightPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        let next = nextValue()
        if next > 0 {
            value = max(value, next)
        }
    }
}
