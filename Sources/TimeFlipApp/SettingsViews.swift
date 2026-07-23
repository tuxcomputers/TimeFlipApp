import AppKit
import SwiftUI

struct SettingsRootView: View {
    @ObservedObject var appState: AppState
    @ObservedObject var authManager: GoogleAuthManager
    let integrationCoordinator: GoogleIntegrationCoordinator
    @State private var selectedTab: SettingsTab = .facets
    let onMinimumContentHeightChange: (CGFloat) -> Void
    let onClose: () -> Void

    init(
        appState: AppState,
        authManager: GoogleAuthManager,
        integrationCoordinator: GoogleIntegrationCoordinator,
        onClose: @escaping () -> Void = {},
        onMinimumContentHeightChange: @escaping (CGFloat) -> Void = { _ in }
    ) {
        self.appState = appState
        self.authManager = authManager
        self.integrationCoordinator = integrationCoordinator
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
    case facets
    case report

    /// Matches the tab's visible title, for the `tab` debug log (see SettingsRootView).
    var debugName: String {
        switch self {
        case .timeflip: return "Device"
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
                        TopFacetEditor(mapping: binding, colourOptions: appState.colourOptions) { facetID, colourID in
                            appState.assignFacetColour(facetID: facetID, colourID: colourID)
                        }
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
    let colourOptions: [ActivityColorOption]
    let onColourPicked: (UInt8, Int) -> Void

    var body: some View {
        let nameBinding = Binding(
            get: { mapping.name },
            set: { mapping.name = ActivityLibrary.sanitizeActivityName($0) }
        )
        let iconBinding = Binding(
            get: { mapping.iconName },
            set: { mapping.iconName = ActivityLibrary.sanitizeIconName($0) }
        )

        VStack(alignment: .leading, spacing: SettingsLayoutConstants.Pane.sectionSpacing) {
            HStack(alignment: .center, spacing: SettingsLayoutConstants.Pane.sectionSpacing) {
                TextField("", text: nameBinding, prompt: Text("Unassigned"))
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .multilineTextAlignment(.leading)

                FacetColorPicker(selection: $mapping.color, colourOptions: colourOptions) { option in
                    onColourPicked(mapping.facetID, option.colourId)
                }
            }

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
            }

            IconGridPicker(selection: iconBinding, tint: mapping.color)
        }
    }
}

private struct ActivityIconView: View {
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
                    selection = ""
                }

                ForEach(ActivityLibrary.iconOptions) { option in
                    IconGridCell(
                        iconName: option.iconName,
                        isSelected: selection == option.iconName,
                        tint: tint
                    ) {
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

/// Custom color picker restricted to the `colour` reference table's palette (passed in as
/// `colourOptions`, sourced from `AppDataStore.loadColours`) instead of AppKit's full color
/// wheel/sliders.
private struct FacetColorPicker: View {
    @Binding var selection: Color
    let colourOptions: [ActivityColorOption]
    let onPick: (ActivityColorOption) -> Void
    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            Circle()
                .fill(selection)
                .overlay(
                    Circle().stroke(
                        Color.secondary.opacity(SettingsLayoutConstants.ColorPicker.swatchStrokeOpacity),
                        lineWidth: SettingsLayoutConstants.ColorPicker.swatchStrokeWidth
                    )
                )
                .frame(
                    width: SettingsLayoutConstants.ColorPicker.swatchButtonSize,
                    height: SettingsLayoutConstants.ColorPicker.swatchButtonSize
                )
        }
        .buttonStyle(.plain)
        .popover(isPresented: $isPresented) {
            ColorOptionList(selection: $selection, colourOptions: colourOptions, onPick: onPick) {
                isPresented = false
            }
        }
    }
}

private struct ColorOptionList: View {
    @Binding var selection: Color
    let colourOptions: [ActivityColorOption]
    let onPick: (ActivityColorOption) -> Void
    let onSelect: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(colourOptions) { option in
                Button {
                    selection = option.color
                    onPick(option)
                    onSelect()
                } label: {
                    HStack(spacing: SettingsLayoutConstants.ColorPicker.rowSpacing) {
                        RoundedRectangle(cornerRadius: SettingsLayoutConstants.ColorPicker.rowSwatchCornerRadius)
                            .fill(option.color)
                            .frame(
                                width: SettingsLayoutConstants.ColorPicker.rowSwatchSize,
                                height: SettingsLayoutConstants.ColorPicker.rowSwatchSize
                            )
                        Text(option.name)
                        Spacer()
                        if selection == option.color {
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
        .padding(SettingsLayoutConstants.ColorPicker.listPadding)
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
