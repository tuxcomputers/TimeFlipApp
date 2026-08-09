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
    let findCategories: (String) -> [CategoryRecord]
    let updateCategoryColour: (Int, Int) -> Void
    let updateCategoryDailyLimit: (Int, Int) -> Void
    let updateCategoryActive: (Int, Bool) -> Bool
    let updateCategoryName: (Int, String) -> Void
    let updateCategoryIcon: (Int, Int) -> Void
    /// Assigns a category to a physical face: `(face_id, category_id)`.
    let assignCategoryToFace: (UInt8, Int) -> Void
    /// Locks or unlocks a physical face: `(face_id, locked)`.
    let setFaceLocked: (UInt8, Bool) -> Void
    /// Tracked seconds per category between two instants, for the Report tab: `(from, to)`.
    let loadCategoryTotals: (Date, Date) -> [CategoryTotalRecord]
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
        findCategories: @escaping (String) -> [CategoryRecord],
        updateCategoryColour: @escaping (Int, Int) -> Void,
        updateCategoryDailyLimit: @escaping (Int, Int) -> Void,
        updateCategoryActive: @escaping (Int, Bool) -> Bool,
        updateCategoryName: @escaping (Int, String) -> Void,
        updateCategoryIcon: @escaping (Int, Int) -> Void,
        assignCategoryToFace: @escaping (UInt8, Int) -> Void,
        setFaceLocked: @escaping (UInt8, Bool) -> Void,
        loadCategoryTotals: @escaping (Date, Date) -> [CategoryTotalRecord],
        onClose: @escaping () -> Void = {},
        onMinimumContentHeightChange: @escaping (CGFloat) -> Void = { _ in }
    ) {
        self.appState = appState
        self.authManager = authManager
        self.integrationCoordinator = integrationCoordinator
        self.loadCategories = loadCategories
        self.createCategory = createCategory
        self.findCategory = findCategory
        self.findCategories = findCategories
        self.updateCategoryColour = updateCategoryColour
        self.updateCategoryDailyLimit = updateCategoryDailyLimit
        self.updateCategoryActive = updateCategoryActive
        self.updateCategoryName = updateCategoryName
        self.updateCategoryIcon = updateCategoryIcon
        self.assignCategoryToFace = assignCategoryToFace
        self.setFaceLocked = setFaceLocked
        self.loadCategoryTotals = loadCategoryTotals
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
                    findCategories: findCategories,
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
                    findCategories: findCategories,
                    updateCategoryActive: updateCategoryActive,
                    assignCategoryToFace: assignCategoryToFace,
                    setFaceLocked: setFaceLocked
                )
                    .tabItem {
                        Text("Faces")
                    }
                    .tag(SettingsTab.faces)
                ReportView(
                    appState: appState,
                    loadCategoryTotals: loadCategoryTotals
                )
                    .tabItem {
                        Text("Report")
                    }
                    .tag(SettingsTab.report)
                ReportSettingsView(
                    appState: appState,
                    authManager: authManager,
                    integrationCoordinator: integrationCoordinator
                )
                    .tabItem {
                        Text("App")
                    }
                    .tag(SettingsTab.app)
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
    /// The Google/app-preferences tab, drawn by `ReportSettingsView`. Named for its visible title
    /// rather than for that view: the view predates the Report tab and took the name first, so
    /// leaving this case called `report` would have pointed the two names at each other's tab.
    case app

    /// Matches the tab's visible title, for the `tab` debug log (see SettingsRootView).
    var debugName: String {
        switch self {
        case .timeflip: return "Device"
        case .categories: return "Categories"
        case .faces: return "Faces"
        case .report: return "Report"
        case .app: return "App"
        }
    }
}

private struct PaneSetupView: View {
    @ObservedObject var appState: AppState
    let loadCategories: () -> [CategoryRecord]
    let createCategory: (String) -> Int?
    let findCategories: (String) -> [CategoryRecord]
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
                    Text(appState.isManualMode ? "Timing" : "Top face")
                        .font(.headline)

                    if appState.isManualMode {
                        manualTimerEditor
                    } else if TimeFlipConstants.isValidFaceID(appState.currentFaceID) {
                        TopFaceEditor(
                            categoryName: appState.categoryActivity(for: appState.currentFaceID)?.name,
                            isLocked: appState.isFaceLocked(appState.currentFaceID),
                            onToggleLock: {
                                let faceID = appState.currentFaceID
                                let locked = !appState.isFaceLocked(faceID)
                                DeveloperMode.debugPrint(.click, "Button clicked: Face \(faceID) lock -> \(locked ? "locked" : "unlocked")")
                                setFaceLocked(faceID, locked)
                            }
                        ) {
                            DeviceFaceView(
                                litColour: appState.deviceBodyColour(for: appState.currentFaceID),
                                lineColour: appState.deviceLineColour(for: appState.currentFaceID),
                                centre: centre(for: appState.currentFaceID)
                            )
                        }
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
                        onSelect: { pickCategory($0) }
                    )

                    CategoryCreateControl(
                        appState: appState,
                        createCategory: createCategory,
                        findCategories: findCategories,
                        // Re-read rather than patched: this list only shows active categories, so a
                        // reinstated one has to appear in it.
                        reactivate: { category in
                            // Nothing to re-read or assign if the reinstate was refused: the
                            // category is still retired, so it would not appear in this list and
                            // must not land on the face either.
                            guard updateCategoryActive(category.id, true) else { return false }
                            categories = loadCategories()
                            pickCategory(category.id)
                            return true
                        },
                        onCreated: { newCategoryID in
                            categories = loadCategories()
                            guard let newCategoryID else { return }
                            pickCategory(newCategoryID)
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

    /// Manual mode's timer control, where the device graphic sits the rest of the time.
    ///
    /// No device is drawn: there is no cube in this mode, so a picture of one would be reporting
    /// nothing. No lock either -- locking exists to stop a face being reassigned by accident, and
    /// manual mode's face is *meant* to be reassigned, since every category the user picks lands on
    /// it, so a lock there could only get in the way of the one gesture this tab has.
    private var manualTimerEditor: some View {
        let state = ManualTimerRules.state(currentFaceID: appState.currentFaceID, isPaused: appState.isPaused)
        let faceID = TimeFlipConstants.manualFaceID
        return TopFaceEditor(
            categoryName: state == .idle ? "" : appState.categoryActivity(for: faceID)?.name,
            isLocked: false,
            onToggleLock: nil,
            onTapCentre: ManualTimerRules.isCentreClickable(state) ? {
                DeveloperMode.debugPrint(.click, "Manual timer clicked while \(state): toggling")
                appState.onManualTimingPauseToggle?()
            } : nil
        ) {
            ManualTimerFaceView(
                centre: ManualTimerRules.centre(for: state),
                tint: appState.faceCategoryColour(for: faceID)
            )
        }
    }

    /// What the centre of the device shows for a real face: its category's icon, if it has one.
    private func centre(for faceID: UInt8) -> DeviceFaceCentre {
        guard let iconName = appState.categoryActivity(for: faceID)?.iconName else { return .empty }
        return .categoryIcon(iconName)
    }

    /// Whether the face on show will take a category: there has to be a real face up, and a locked
    /// face keeps the one it already has. Manual mode's face is always ready for one, being the
    /// whole point of the tab there. Read by the assignment list to decide whether its rows are
    /// live, and by `pickCategory` for the same question, so the two cannot disagree.
    private var canAssignToFaceOnShow: Bool {
        if appState.isManualMode { return true }
        return TimeFlipConstants.isValidFaceID(appState.currentFaceID)
            && !appState.isFaceLocked(appState.currentFaceID)
    }

    /// The one gesture this tab has: a category is chosen, from the list or by being created or
    /// reinstated right here.
    ///
    /// Creating a category on *this* tab is done while looking at a particular face, and that face is
    /// the reason it is being created, so it lands there rather than leaving the user to find the new
    /// row in the list below and click it. The Categories tab, which has no face in front of it,
    /// creates without assigning -- which is why this lives here and not in `CategoryCreateControl`.
    ///
    /// It overwrites whatever the face held: the face was unlocked and the user asked for this
    /// category while on it, which is the same instruction either way.
    ///
    /// In manual mode the choice also **starts the clock**, which is why it goes out through
    /// `onManualTimingStart` rather than writing the face row from here. Closing the running segment
    /// before the new category lands is the whole of that job, and getting the order wrong records
    /// time against the wrong thing -- see `ApplicationDelegate.startManualTiming`.
    ///
    /// Does nothing when the face won't take it -- no face reported yet, or a locked one. Neither
    /// needs saying twice: the list beside this is already visibly dead and the lock already reads
    /// red, and the write itself refuses a locked face anyway.
    private func pickCategory(_ categoryID: Int) {
        guard canAssignToFaceOnShow else {
            let faceID = appState.currentFaceID
            DeveloperMode.debugPrint(.click, "Category \(categoryID) left unassigned: face \(faceID) is \(appState.isFaceLocked(faceID) ? "locked" : "not a face")")
            return
        }
        if appState.isManualMode {
            DeveloperMode.debugPrint(.click, "Category \(categoryID) picked in manual mode; starting the clock")
            appState.onManualTimingStart?(categoryID)
            return
        }
        DeveloperMode.debugPrint(.click, "Category \(categoryID) assigned to the top face \(appState.currentFaceID)")
        assignCategoryToFace(appState.currentFaceID, categoryID)
    }
}

/// The square at the top of the left column, with the category's name under it.
///
/// Generic over what fills the square because the two modes have nothing in common there: with a
/// cube it is the device artwork lit in the face's colour, and in manual mode there is no device, so
/// it is the timer control alone on the window. Everything around it -- the square footprint the
/// column's height is measured from, the name, the optional lock and the optional click target --
/// is shared, which is what keeps the two from drifting apart in spacing or type.
private struct TopFaceEditor<Face: View>: View {
    /// The assigned category's name, shown under the square.
    let categoryName: String?
    let isLocked: Bool
    /// `nil` hides the lock entirely, which is what manual mode wants -- it has no lock to offer,
    /// rather than a lock that is merely switched off.
    let onToggleLock: (() -> Void)?
    /// Makes the centre of the square a click target. `nil` leaves it inert, which is every case
    /// except manual mode's play/pause.
    var onTapCentre: (() -> Void)?
    @ViewBuilder let face: () -> Face

    var body: some View {
        VStack(spacing: SettingsLayoutConstants.Pane.sectionSpacing) {
            // The face squares itself off, so the name sits directly under it rather than being
            // pushed to the bottom of a tall column.
            face()
                .overlay(alignment: .topLeading) {
                    if let onToggleLock {
                        FaceLockToggle(isLocked: isLocked, action: onToggleLock)
                    }
                }
                .overlay {
                    if let onTapCentre {
                        // Sized to the centre rather than the whole square, so the click lands on
                        // the icon a user is aiming at and the rest stays inert.
                        GeometryReader { proxy in
                            Button(action: onTapCentre) {
                                Color.clear.contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .frame(
                                width: proxy.size.width * SettingsLayoutConstants.DeviceFace.centreIconScale,
                                height: proxy.size.width * SettingsLayoutConstants.DeviceFace.centreIconScale
                            )
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                        }
                    }
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
    /// What sits on the centre face.
    let centre: DeviceFaceCentre

    var body: some View {
        device
            .aspectRatio(1, contentMode: .fit)
            // An overlay is sized by what it covers, so reading the geometry here scales the icon
            // to the device without the icon's size feeding back into the layout.
            .overlay {
                GeometryReader { proxy in
                    // The centre face is centred on the artwork, so centring the icon in the same
                    // frame puts it on that face without needing the pentagon's corners.
                    FaceCentreView(
                        centre: centre,
                        tint: lineColour,
                        size: proxy.size.width * SettingsLayoutConstants.DeviceFace.centreIconScale
                    )
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

/// Manual mode's face: the timer control alone, on the window.
///
/// No device is drawn behind it, because in manual mode there is no device. Keeping the artwork and
/// putting the control on its centre face would draw a cube for a session that has nothing to do
/// with one, and invite the reading that the picture is reporting something about hardware.
///
/// It still takes the same square footprint the device did, so the name below it and the rest of
/// the column sit where they always have.
struct ManualTimerFaceView: View {
    let centre: DeviceFaceCentre
    /// The category's own colour, or `.primary` when it has none -- `AppState.faceCategoryColour`,
    /// not `deviceLineColour`. The latter answers "what reads against the lit device body" and is
    /// white for a dark face, which on the window behind it would be a white icon on white.
    let tint: Color

    var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                GeometryReader { proxy in
                    FaceCentreView(
                        centre: centre,
                        tint: tint,
                        size: proxy.size.width * SettingsLayoutConstants.DeviceFace.centreIconScale
                    )
                }
            }
    }
}

/// What sits in the middle of the square, centred in whatever it is given.
private struct FaceCentreView: View {
    let centre: DeviceFaceCentre
    let tint: Color
    let size: CGFloat

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    @ViewBuilder
    private var content: some View {
        switch centre {
        case .empty:
            EmptyView()
        case .categoryIcon(let iconName):
            ActivityIconView(iconName: iconName, tint: tint, size: size)
        case .symbol(let symbolName):
            // An SF Symbol rather than the asset loader `ActivityIconView` uses: the category icons
            // come from the app's own asset catalogue, and the timer's play/pause are not categories.
            Image(systemName: symbolName)
                .resizable()
                .scaledToFit()
                .foregroundStyle(tint)
                .frame(width: size, height: size)
        }
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

private struct FacesColumnHeightPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        let next = nextValue()
        if next > 0 {
            value = max(value, next)
        }
    }
}
