import AppKit
import SwiftUI

struct SettingsRootView: View {
    @ObservedObject var appState: AppState
    @ObservedObject var authManager: GoogleAuthManager
    let integrationCoordinator: GoogleIntegrationCoordinator
    @State private var selectedTab: SettingsTab = .facets
    let onMinimumContentHeightChange: (CGFloat) -> Void

    init(
        appState: AppState,
        authManager: GoogleAuthManager,
        integrationCoordinator: GoogleIntegrationCoordinator,
        onMinimumContentHeightChange: @escaping (CGFloat) -> Void = { _ in }
    ) {
        self.appState = appState
        self.authManager = authManager
        self.integrationCoordinator = integrationCoordinator
        self.onMinimumContentHeightChange = onMinimumContentHeightChange
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            TimeFlipSettingsView(appState: appState)
                .tabItem {
                    Text("TimeFlip")
                }
                .tag(SettingsTab.timeflip)
            PaneSetupView(appState: appState)
                .tabItem {
                    Text("Facets")
                }
                .tag(SettingsTab.facets)
            ReportSettingsView(
                appState: appState,
                authManager: authManager,
                integrationCoordinator: integrationCoordinator
            )
                .tabItem {
                    Text("Report")
                }
                .tag(SettingsTab.report)
        }
        .frame(minWidth: SettingsLayoutConstants.minimumWindowWidth)
        .onPreferenceChange(FacetsColumnHeightPreferenceKey.self) { height in
            guard height > 0 else { return }
            onMinimumContentHeightChange(height)
        }
    }
}

private enum SettingsTab: Hashable {
    case timeflip
    case facets
    case report
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
                    Text("Facets")
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

private struct ReportSettingsView: View {
    @ObservedObject var appState: AppState
    @ObservedObject var authManager: GoogleAuthManager
    let integrationCoordinator: GoogleIntegrationCoordinator

    @State private var calendars: [GoogleCalendarSummary] = []
    @State private var isLoadingCalendars = false
    @State private var calendarError: String?
    @State private var isEditingSheetURL = false
    @State private var sheetURLDraft = ""
    @State private var sheetSyncError: String?
    @FocusState private var sheetURLFieldFocused: Bool

    var body: some View {
        Form {
            Section("Google") {
                credentialsSection
                Divider()

                if !integrationsEnabled {
                    Text(
                        """
                        Google Calendar and Sheets sync are disabled for this build;
                        events stay local while we debug history.
                        """
                    )
                    .foregroundStyle(.secondary)
                } else {
                    authSection
                    Divider()
                    calendarSection
                    Divider()
                    sheetSection
                }
            }
        }
        .formStyle(.grouped)
        .task(id: authManager.isAuthenticated) {
            guard integrationsEnabled else { return }
            if authManager.isAuthenticated {
                await loadCalendars()
            } else {
                calendars = []
                calendarError = nil
            }
        }
    }

    private var integrationsEnabled: Bool {
        integrationCoordinator.isEnabled
    }

    private var credentialsReady: Bool {
        hasClientID && hasClientSecret
    }

    private var hasClientID: Bool {
        !appState.googleClientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var hasClientSecret: Bool {
        !appState.googleClientSecret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    @ViewBuilder private var credentialsSection: some View {
        LabeledContent("Client ID") {
            SecureField(
                "Paste OAuth client ID",
                text: Binding(
                    get: { appState.googleClientID },
                    set: { appState.googleClientID = $0 }
                )
            )
            .textFieldStyle(.roundedBorder)
            .disableAutocorrection(true)
        }

        LabeledContent("Client Secret") {
            SecureField(
                "Paste OAuth client secret",
                text: Binding(
                    get: { appState.googleClientSecret },
                    set: { appState.googleClientSecret = $0 }
                )
            )
            .textFieldStyle(.roundedBorder)
            .disableAutocorrection(true)
        }

        if !credentialsReady {
            Text("Paste your Google OAuth client ID and secret to enable sign-in.")
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var authSection: some View {
        if authManager.isAuthenticated {
            LabeledContent("Status") {
                Text("Connected")
            }
            Button("Sign out") {
                authManager.signOut()
            }
        } else {
            Button(authManager.isAuthenticating ? "Authenticating..." : "Google Auth") {
                Task { @MainActor in
                    await authManager.authenticate()
                }
            }
            .disabled(authManager.isAuthenticating || !credentialsReady)
        }

        if let errorMessage = authManager.errorMessage {
            Text(errorMessage)
                .foregroundStyle(.red)
        }
    }

    @ViewBuilder private var calendarSection: some View {
        if authManager.isAuthenticated {
            if isLoadingCalendars {
                LabeledContent("Calendars") {
                    ProgressView()
                }
            } else if calendars.isEmpty {
                Button("Load calendars") {
                    Task { @MainActor in
                        await loadCalendars()
                    }
                }
            } else {
                Picker("Calendar", selection: calendarSelectionBinding) {
                    Text("None").tag("")
                    ForEach(calendars) { calendar in
                        Text(calendar.summary).tag(calendar.id)
                    }
                }
            }

            if let calendarError {
                Text(calendarError)
                    .foregroundStyle(.red)
            }

            Button("Refresh calendars") {
                Task { @MainActor in
                    await loadCalendars()
                }
            }
            .disabled(isLoadingCalendars)
        } else {
            Text("Authenticate to load calendars.")
                .foregroundStyle(.secondary)
        }
    }

    private var calendarSelectionBinding: Binding<String> {
        Binding(
            get: { appState.googleCalendarID ?? "" },
            set: { newValue in
                let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                appState.googleCalendarID = trimmed.isEmpty ? nil : trimmed
                appState.googleCalendarName = calendars.first { $0.id == trimmed }?.summary
            }
        )
    }

    @ViewBuilder private var sheetSection: some View {
        let currentURL = appState.googleSheetURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasURL = !currentURL.isEmpty

        if isEditingSheetURL {
            TextField("", text: $sheetURLDraft)
            .textFieldStyle(.roundedBorder)
            .focused($sheetURLFieldFocused)
            .onSubmit {
                saveSheetURL()
            }
            .onKeyPress(.escape) {
                cancelEditingSheetURL()
                return .handled
            }
            .onChange(of: sheetURLFieldFocused) { _, isFocused in
                if !isFocused {
                    cancelEditingSheetURL()
                }
            }
        } else {
            LabeledContent("Sheet URL") {
                HStack {
                    Button(hasURL ? "Update" : "Set") {
                        startEditingSheetURL()
                    }

                    if hasURL {
                        Button("Open") {
                            if let url = URL(string: currentURL) {
                                NSWorkspace.shared.open(url)
                            }
                        }
                    }
                }
            }
        }

        if let error = sheetSyncError {
            Text(error)
                .foregroundStyle(.red)
        }
    }

    private func startEditingSheetURL() {
        let currentURL = appState.googleSheetURL.trimmingCharacters(in: .whitespacesAndNewlines)

        if currentURL.isEmpty {
            // Check clipboard for Google Sheets URL
            if let clipboardString = NSPasteboard.general.string(forType: .string),
               clipboardString.hasPrefix("https://docs.google.com/spreadsheets/d/") {
                sheetURLDraft = clipboardString
            } else {
                sheetURLDraft = ""
            }
        } else {
            sheetURLDraft = currentURL
        }

        isEditingSheetURL = true
        sheetURLFieldFocused = true
    }

    private func cancelEditingSheetURL() {
        isEditingSheetURL = false
        sheetURLFieldFocused = false
        sheetURLDraft = ""
    }

    private func saveSheetURL() {
        let trimmed = sheetURLDraft.trimmingCharacters(in: .whitespacesAndNewlines)

        // Empty value clears the URL
        if trimmed.isEmpty {
            appState.googleSheetURL = ""
            sheetSyncError = nil
            cancelEditingSheetURL()
            return
        }

        // Validate URL prefix
        if !trimmed.hasPrefix("https://docs.google.com/spreadsheets/d/") {
            sheetSyncError = "URL must start with https://docs.google.com/spreadsheets/d/"
            return
        }

        // Additional validation using existing parser
        if GoogleSheetDestination.parse(from: trimmed) == nil {
            sheetSyncError = "Invalid Google Sheets URL format"
            return
        }

        // Save and close
        appState.googleSheetURL = trimmed
        sheetSyncError = nil
        cancelEditingSheetURL()
    }

    @MainActor
    private func loadCalendars() async {
        guard integrationsEnabled else { return }
        guard !isLoadingCalendars else { return }
        isLoadingCalendars = true
        calendarError = nil
        do {
            let fetched = try await integrationCoordinator.fetchCalendars()
            calendars = fetched.sorted { $0.summary.lowercased() < $1.summary.lowercased() }
        } catch {
            calendarError = error.localizedDescription
        }
        isLoadingCalendars = false
    }
}

private struct TopFacetEditor: View {
    @Binding var mapping: FacetMapping

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

                ColorPicker("", selection: $mapping.color, supportsOpacity: false)
                    .labelsHidden()
            }

            HStack(spacing: SettingsLayoutConstants.Pane.sectionSpacing) {
                Text("Limit:")
                Stepper(
                    value: $mapping.limitMinutes,
                    in: 0...480,
                    step: 5
                ) {
                    Text(mapping.limitMinutes == 0 ? "No limit" : "\(mapping.limitMinutes) min")
                        .frame(minWidth: 80, alignment: .leading)
                }
                .help("0 = no limit; max 480 minutes; steps of 5 minutes.")
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
                Text("\(mapping.limitMinutes) min")
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
