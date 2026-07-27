import AppKit
import SwiftUI

struct SettingsRootView: View {
    @ObservedObject var appState: AppState
    @ObservedObject var authManager: GoogleAuthManager
    let integrationCoordinator: GoogleIntegrationCoordinator
    let loadCategories: () -> [CategoryRecord]
    let createCategory: (String) -> Void
    let findCategory: (String) -> CategoryRecord?
    let updateCategoryColour: (Int, Int) -> Void
    let updateCategoryDailyLimit: (Int, Int) -> Void
    let updateCategoryActive: (Int, Bool) -> Void
    let updateCategoryIcon: (Int, Int) -> Void
    @State private var selectedTab: SettingsTab = .facets
    let onMinimumContentHeightChange: (CGFloat) -> Void
    let onClose: () -> Void

    init(
        appState: AppState,
        authManager: GoogleAuthManager,
        integrationCoordinator: GoogleIntegrationCoordinator,
        loadCategories: @escaping () -> [CategoryRecord],
        createCategory: @escaping (String) -> Void,
        findCategory: @escaping (String) -> CategoryRecord?,
        updateCategoryColour: @escaping (Int, Int) -> Void,
        updateCategoryDailyLimit: @escaping (Int, Int) -> Void,
        updateCategoryActive: @escaping (Int, Bool) -> Void,
        updateCategoryIcon: @escaping (Int, Int) -> Void,
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
        self.updateCategoryIcon = updateCategoryIcon
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
                    updateCategoryIcon: updateCategoryIcon
                )
                    .tabItem {
                        Text("Categories")
                    }
                    .tag(SettingsTab.categories)
                PaneSetupView(appState: appState)
                    .tabItem {
                        Text("Faces")
                    }
                    .tag(SettingsTab.facets)
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
            .onPreferenceChange(FacetsColumnHeightPreferenceKey.self) { height in
                guard height > 0 else { return }
                onMinimumContentHeightChange(height)
            }
            HStack {
                Spacer()
                Button("Close") {
                    DeveloperMode.debugPrint(.click, "Button clicked: Close (Settings window)")
                    onClose()
                }
                .keyboardShortcut(.cancelAction)
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
    case facets
    case report

    /// Matches the tab's visible title, for the `tab` debug log (see SettingsRootView).
    var debugName: String {
        switch self {
        case .timeflip: return "Device"
        case .categories: return "Categories"
        case .facets: return "Faces"
        case .report: return "App"
        }
    }
}

private struct PaneSetupView: View {
    @ObservedObject var appState: AppState

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
                    Text("Top facet")
                        .font(.headline)

                    if let index = appState.mappingIndex(for: appState.currentFacetID) {
                        let binding = Binding(
                            get: { appState.facetMappings[index] },
                            set: { appState.updateMapping($0) }
                        )
                        TopFacetEditor(mapping: binding)
                    } else {
                        Text("Flip the device to pick a facet.")
                            .foregroundStyle(.secondary)
                            .padding(.vertical, SettingsLayoutConstants.Pane.emptyStateVerticalPadding)
                    }
                }
                .frame(width: leftWidth, alignment: .topLeading)
                .frame(maxHeight: .infinity, alignment: .topLeading)

                VStack(alignment: .leading, spacing: SettingsLayoutConstants.Pane.sectionSpacing) {
                    Text("Faces")
                        .font(.headline)

                    FacetMappingList(
                        mappings: appState.facetMappings,
                        currentFacetID: appState.currentFacetID
                    )
                }
                .frame(width: rightWidth, alignment: .leading)
                .background(
                    GeometryReader { columnProxy in
                        Color.clear.preference(
                            key: FacetsColumnHeightPreferenceKey.self,
                            value: columnProxy.size.height + (verticalPadding * 2)
                        )
                    }
                )
            }
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, verticalPadding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        // swiftlint:enable closure_body_length
    }
}

private struct TopFacetEditor: View {
    @Binding var mapping: FacetMapping

    var body: some View {
        let nameBinding = Binding(
            get: { mapping.name },
            set: {
                let sanitized = ActivityLibrary.sanitizeActivityName($0)
                DeveloperMode.debugPrint(.field, "Field changed: Facet \(mapping.facetID) name: \"\(mapping.name)\" -> \"\(sanitized)\"")
                mapping.name = sanitized
            }
        )
        let iconBinding = Binding(
            get: { mapping.iconName },
            set: {
                let sanitized = ActivityLibrary.sanitizeIconName($0)
                DeveloperMode.debugPrint(.field, "Field changed: Facet \(mapping.facetID) icon: \"\(mapping.iconName)\" -> \"\(sanitized)\"")
                mapping.iconName = sanitized
            }
        )

        VStack(alignment: .leading, spacing: SettingsLayoutConstants.Pane.sectionSpacing) {
            TextField("", text: nameBinding, prompt: Text("Unassigned"))
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: .infinity, alignment: .leading)
                .multilineTextAlignment(.leading)

            HStack(spacing: SettingsLayoutConstants.Pane.sectionSpacing) {
                Text("Daily Limit:")
                Stepper(
                    value: $mapping.limitMinutes,
                    in: 0...480,
                    step: 5
                ) {
                    Text(mapping.limitMinutes == 0 ? "No limit" : "\(mapping.limitMinutes) min/day")
                        .frame(minWidth: 80, alignment: .leading)
                }
                .help("0 = no limit; resets daily at 3am; max 480 minutes; steps of 5 minutes.")
                .onChange(of: mapping.limitMinutes) { oldValue, newValue in
                    DeveloperMode.debugPrint(.field, "Field changed: Facet \(mapping.facetID) daily limit: \(oldValue)m -> \(newValue)m")
                }
            }

            IconGridPicker(selection: iconBinding, tint: mapping.color)
        }
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

struct ColorOptionList: View {
    @Binding var selection: Color
    let colourOptions: [ActivityColorOption]
    let onPick: (ActivityColorOption) -> Void
    let onSelect: () -> Void
    /// Non-nil prepends a hollow "None" row (matching the None-colour swatch style), labelled
    /// with this name, that picks `colour_id 0` -- the caller's job to supply the `colour` table's
    /// own name for that row (see `AppState.noColourName`) rather than a hardcoded string. `nil`
    /// omits the row entirely -- the Faces tab's picker, which has no such concept, passes nil.
    var noneOptionName: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let noneOptionName {
                ColorOptionRow(name: noneOptionName, swatchColor: nil, isSelected: false) {
                    DeveloperMode.debugPrint(.click, "Button clicked: Color option \"\(noneOptionName)\"")
                    let noneOption = ActivityColorOption(colourId: 0, name: noneOptionName, color: .clear)
                    selection = noneOption.color
                    onPick(noneOption)
                    onSelect()
                }
            }
            ForEach(colourOptions) { option in
                ColorOptionRow(name: option.name, swatchColor: option.color, isSelected: selection == option.color) {
                    DeveloperMode.debugPrint(.click, "Button clicked: Color option \"\(option.name)\"")
                    selection = option.color
                    onPick(option)
                    onSelect()
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
    /// `nil` renders a hollow (unfilled, black-stroked) square instead of a colour fill -- used
    /// for the "None" row.
    let swatchColor: Color?
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: SettingsLayoutConstants.ColorPicker.rowSpacing) {
                RoundedRectangle(cornerRadius: SettingsLayoutConstants.ColorPicker.rowSwatchCornerRadius)
                    .fill(swatchColor ?? .clear)
                    .overlay {
                        if swatchColor == nil {
                            RoundedRectangle(cornerRadius: SettingsLayoutConstants.ColorPicker.rowSwatchCornerRadius)
                                .stroke(Color.black)
                        }
                    }
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

private struct FacetMappingList: View {
    let mappings: [FacetMapping]
    let currentFacetID: UInt8

    var body: some View {
        VStack(spacing: 0) {
            ForEach(mappings) { mapping in
                FacetMappingRow(mapping: mapping, isSelected: mapping.facetID == currentFacetID)
                if mapping.id != mappings.last?.id {
                    Divider()
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: SettingsLayoutConstants.FacetList.cornerRadius)
                .fill(Color(NSColor.textBackgroundColor))
        )
    }
}

private struct FacetMappingRow: View {
    let mapping: FacetMapping
    let isSelected: Bool

    var body: some View {
        HStack(spacing: SettingsLayoutConstants.FacetList.rowSpacing) {
            ActivityIconView(
                iconName: mapping.iconName,
                tint: mapping.color,
                size: SettingsLayoutConstants.FacetList.iconSize
            )

            Text(mapping.displayName)
                .foregroundStyle(mapping.isAssigned ? .primary : .secondary)

            Spacer()

            if mapping.limitMinutes > 0 {
                Text("\(mapping.limitMinutes) min/day")
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 70, alignment: .trailing)
            }
        }
        .frame(height: SettingsLayoutConstants.facetRowHeight)
        .padding(.horizontal, SettingsLayoutConstants.FacetList.horizontalPadding)
        .background(
            isSelected
            ? Color.accentColor.opacity(SettingsLayoutConstants.FacetList.selectionOpacity)
            : Color.clear
        )
    }
}

private struct FacetsColumnHeightPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        let next = nextValue()
        if next > 0 {
            value = max(value, next)
        }
    }
}
