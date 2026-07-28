import AppKit
import SwiftUI

struct ReportSettingsView: View {
    @ObservedObject var appState: AppState
    @ObservedObject var authManager: GoogleAuthManager
    let integrationCoordinator: GoogleIntegrationCoordinator

    @State private var isLoadingCalendars = false
    @State private var calendarError: String?
    @State private var account: GoogleAccountInfo?
    @State private var accountError: String?
    // "New calendar" flow: whether the name field is showing, its contents, an in-flight create,
    // and the already-existing calendar awaiting the "use it?" confirmation.
    @State private var isCreatingCalendar = false
    @State private var newCalendarName = Self.defaultNewCalendarName
    @State private var isSavingCalendar = false
    @State private var existingCalendar: GoogleCalendarSummary?
    @State private var showExistingCalendarAlert = false

    private static let defaultNewCalendarName = "TimeFlipApp"

    var body: some View {
        Form {
            Section("Google") {
                // Once verified (authenticated), the Client ID/Secret fields are no longer needed,
                // so drop them and let the Status line lead the section.
                if !authManager.isAuthenticated {
                    credentialsSection
                }

                if !integrationsEnabled {
                    Text(
                        """
                        Google Calendar sync is disabled for this build;
                        events stay local while we debug history.
                        """
                    )
                    .foregroundStyle(.secondary)
                } else {
                    authSection
                    calendarSection
                }
            }

            appSettingsSection
        }
        .formStyle(.grouped)
        // Runs on every appearance of this tab, not just when isAuthenticated changes, so everything
        // it does has to be cheap on a revisit: loadAccount is cache-first, and the calendars are
        // only listed when there is nothing to show without them.
        .task(id: authManager.isAuthenticated) {
            guard integrationsEnabled else { return }
            if authManager.isAuthenticated {
                await loadAccount()
                if needsCalendarList {
                    await loadCalendars()
                }
            } else {
                appState.googleCalendars = nil
                calendarError = nil
                account = nil
                accountError = nil
                // Signed out: drop the cached identity so a later sign-in re-fetches fresh.
                integrationCoordinator.clearCachedAccountInfo()
            }
        }
        .alert(
            "Calendar already exists",
            isPresented: $showExistingCalendarAlert,
            presenting: existingCalendar
        ) { calendar in
            Button("Use it") {
                DeveloperMode.debugPrint(.click, "Button clicked: Use it (existing-calendar alert)")
                selectCalendar(calendar)
                finishCreatingCalendar()
            }
            Button("Cancel", role: .cancel) {
                DeveloperMode.debugPrint(.click, "Button clicked: Cancel (existing-calendar alert)")
                // Leave the name field open so a different name can be entered.
                existingCalendar = nil
            }
        } message: { calendar in
            Text("A calendar named \"\(calendar.summary)\" already exists. Use it instead of creating a new one?")
        }
    }

    // MARK: - App settings

    /// AM/PM half of the 12-hour picker. The stored value stays 24-hour (`appState.dailyResetHour`);
    /// this only drives the display.
    private enum Meridiem: Hashable {
        case am, pm
    }

    @ViewBuilder private var appSettingsSection: some View {
        Section("App settings") {
            LabeledContent("Show seconds in the menu bar") {
                Toggle("", isOn: Binding(
                    get: { appState.displaySecondsEnabled },
                    set: { appState.setDisplaySeconds($0) }
                ))
                .labelsHidden()
            }
            LabeledContent("Pause the device when locking it") {
                Toggle("", isOn: Binding(
                    get: { appState.pauseOnLockEnabled },
                    set: { appState.setPauseOnLock($0) }
                ))
                .labelsHidden()
            }
            LabeledContent("Daily reset at") {
                HStack(spacing: SettingsLayoutConstants.Stepper.meridiemGap) {
                    // The hour is typed or held; AM/PM stays arrows-only, since a two-state value has
                    // nothing to run through and nothing sensible to type.
                    SteppedNumberField(
                        appState: appState,
                        holdKey: "dailyResetHour",
                        value: Self.to12Hour(appState.dailyResetHour).hour,
                        range: 1...12,
                        suffix: "",
                        fieldWidth: SettingsLayoutConstants.Stepper.hourFieldWidth,
                        onCommit: setHour12
                    )
                    HStack(spacing: SettingsLayoutConstants.Stepper.itemSpacing) {
                        Text(Self.to12Hour(appState.dailyResetHour).meridiem == .am ? "AM" : "PM")
                            .frame(width: SettingsLayoutConstants.Stepper.meridiemLabelWidth, alignment: .leading)
                        stepArrows(up: toggleMeridiem, down: toggleMeridiem)
                    }
                }
            }
            LabeledContent("Battery warning at") {
                SteppedNumberField(
                    appState: appState,
                    holdKey: "batteryWarning",
                    value: appState.lowBatteryThresholdPercent,
                    range: Int(TimeFlipConstants.minBatteryLevel)...TimeFlipConstants.effectiveMaxLowBatteryWarningPercent,
                    suffix: "%",
                    fieldWidth: SettingsLayoutConstants.Stepper.fieldWidth(
                        suffixWidth: SettingsLayoutConstants.Stepper.percentSuffixWidth
                    ),
                    suffixWidth: SettingsLayoutConstants.Stepper.percentSuffixWidth,
                    onCommit: { appState.setLowBatteryThreshold($0) }
                )
            }
            LabeledContent("Fetch history every") {
                SteppedNumberField(
                    appState: appState,
                    holdKey: "fetchHistory",
                    value: fetchIntervalMinutes,
                    range: fetchIntervalMinutesRange,
                    suffix: fetchIntervalMinutes == 1 ? "min" : "mins",
                    fieldWidth: SettingsLayoutConstants.Stepper.fieldWidth(
                        suffixWidth: SettingsLayoutConstants.Stepper.minutesSuffixWidth
                    ),
                    suffixWidth: SettingsLayoutConstants.Stepper.minutesSuffixWidth,
                    onCommit: { appState.setFetchHistoryIntervalSeconds($0 * Int(TimeConstants.secondsPerMinute)) }
                )
            }
        }
    }

    /// The stacked up/down chevron pair used by the auto-pause stepper (see
    /// `TimeFlipSettingsView.autoPauseStepButton`). Hour/AM-PM ranges are tiny, so a plain tap is
    /// enough -- no press-and-hold accelerating repeat is needed here.
    private func stepArrows(up: @escaping () -> Void, down: @escaping () -> Void) -> some View {
        VStack(spacing: 1) {
            stepArrow("chevron.up", action: up)
            stepArrow("chevron.down", action: down)
        }
    }

    private func stepArrow(_ systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(width: 16, height: 10)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Applies an hour picked on the 12-hour face, keeping AM/PM as it is. The face value is clamped
    /// by the control rather than wrapped: with a field to type into, wrapping 12 round to 1 would
    /// mean a typed 13 silently became 1.
    private func setHour12(_ hour12: Int) {
        let current = Self.to12Hour(appState.dailyResetHour)
        let newHour = Self.to24Hour(hour12: hour12, meridiem: current.meridiem)
        guard newHour != appState.dailyResetHour else { return }
        DeveloperMode.debugPrint(.field, "Field changed: Daily reset hour: \(appState.dailyResetHour) -> \(newHour) (24h)")
        appState.setDailyResetTime(hour: newHour, minute: appState.dailyResetMinute)
    }

    /// The stored interval as whole minutes. This control is the only place the value is thought of
    /// in minutes; everywhere else, including `AppState`, it stays in seconds. Rounds down, so a
    /// sub-minute interval (developer mode only) reads as 0 rather than being dressed up as 1.
    private var fetchIntervalMinutes: Int {
        appState.fetchHistoryIntervalSeconds / Int(TimeConstants.secondsPerMinute)
    }

    /// The interval bounds expressed in whole minutes, for the control. Everywhere else they stay in
    /// seconds -- see `TimeFlipConstants.minFetchHistoryIntervalSeconds`.
    private var fetchIntervalMinutesRange: ClosedRange<Int> {
        let perMinute = Int(TimeConstants.secondsPerMinute)
        let low = TimeFlipConstants.minFetchHistoryIntervalSeconds / perMinute
        let high = TimeFlipConstants.maxFetchHistoryIntervalSeconds / perMinute
        return low...high
    }

    /// Flips AM<->PM, keeping the hour on the clock face fixed.
    private func toggleMeridiem() {
        let current = Self.to12Hour(appState.dailyResetHour)
        let flipped: Meridiem = current.meridiem == .am ? .pm : .am
        let newHour = Self.to24Hour(hour12: current.hour, meridiem: flipped)
        DeveloperMode.debugPrint(.field, "Field changed: Daily reset meridiem: \(current.meridiem == .am ? "AM" : "PM") -> \(flipped == .am ? "AM" : "PM") (hour \(appState.dailyResetHour) -> \(newHour) 24h)")
        appState.setDailyResetTime(
            hour: newHour,
            minute: appState.dailyResetMinute
        )
    }

    /// 24-hour hour (0-23) → 12-hour clock face (1-12) plus AM/PM. 0 → 12 AM, 12 → 12 PM.
    private static func to12Hour(_ hour24: Int) -> (hour: Int, meridiem: Meridiem) {
        let meridiem: Meridiem = hour24 < 12 ? .am : .pm
        let hour12 = hour24 % 12
        return (hour12 == 0 ? 12 : hour12, meridiem)
    }

    /// 12-hour clock face (1-12) plus AM/PM → 24-hour hour (0-23). 12 AM → 0, 12 PM → 12.
    private static func to24Hour(hour12: Int, meridiem: Meridiem) -> Int {
        let base = hour12 % 12
        return meridiem == .pm ? base + 12 : base
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
            // The client ID is not a secret (it appears in every OAuth URL),
            // so keep it visible for paste verification.
            TextField(
                "Paste OAuth client ID",
                text: Binding(
                    get: { appState.googleClientID },
                    set: {
                        DeveloperMode.debugPrint(.field, "Field changed: Google Client ID: \(appState.googleClientID.count)ch -> \($0.count)ch")
                        appState.googleClientID = $0
                    }
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
                    set: {
                        // Never log the secret's value -- only that (and by how much) it changed.
                        DeveloperMode.debugPrint(.field, "Field changed: Google Client Secret: \(appState.googleClientSecret.count)ch -> \($0.count)ch (value hidden)")
                        appState.googleClientSecret = $0
                    }
                )
            )
            .textFieldStyle(.roundedBorder)
            .disableAutocorrection(true)
        }
    }

    @ViewBuilder private var authSection: some View {
        if authManager.isAuthenticated {
            LabeledContent("Status") {
                Text("Connected")
            }
            if let name = account?.name, !name.isEmpty {
                LabeledContent("Account") {
                    Text(name)
                }
            }
            if let email = account?.email, !email.isEmpty {
                LabeledContent("Email") {
                    Text(email)
                }
            }
            if let accountError {
                Text(accountError)
                    .foregroundStyle(.secondary)
            }
        } else {
            HStack {
                Button(authManager.isAuthenticating ? "Authenticating..." : "Google Auth") {
                    DeveloperMode.debugPrint(.click, "Button clicked: Google Auth")
                    Task { @MainActor in
                        await authManager.authenticate()
                    }
                }
                .disabled(authManager.isAuthenticating || !credentialsReady)

                if !credentialsReady {
                    Text("Paste your Google OAuth client ID and secret to enable sign-in.")
                        .foregroundStyle(.secondary)
                }
            }
        }

        if let errorMessage = authManager.errorMessage {
            Text(errorMessage)
                .foregroundStyle(.red)
        }
    }

    /// The calendars listed so far, treating "never listed" the same as "none".
    private var calendars: [GoogleCalendarSummary] {
        appState.googleCalendars ?? []
    }

    /// The calendar currently synced into, as saved in the `google_account` setting. Known without
    /// listing anything, which is what lets the section open with no network call.
    private var savedCalendarName: String? {
        appState.googleCalendarName.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Whether the section can't say anything useful without a `calendars.list` call: no list yet and
    /// no saved calendar to name. Once either is true, listing waits until it is actually needed --
    /// changing the selection (Refresh calendars) or checking a new calendar's name for a duplicate.
    private var needsCalendarList: Bool {
        appState.googleCalendars == nil && savedCalendarName == nil
    }

    @ViewBuilder private var calendarSection: some View {
        if authManager.isAuthenticated {
            if isLoadingCalendars {
                LabeledContent("Calendars") {
                    ProgressView()
                }
            } else if !calendars.isEmpty {
                Picker("Calendar", selection: calendarSelectionBinding) {
                    Text("None").tag("")
                    ForEach(calendars) { calendar in
                        Text(calendar.summary).tag(calendar.id)
                    }
                }
            } else if let savedCalendarName {
                // Nothing listed, but the saved selection is still worth showing; Refresh calendars
                // below turns this back into a picker when the selection needs changing.
                LabeledContent("Calendar") {
                    Text(savedCalendarName)
                }
            } else {
                Button("Load calendars") {
                    DeveloperMode.debugPrint(.click, "Button clicked: Load calendars")
                    Task { @MainActor in
                        await loadCalendars()
                    }
                }
            }

            if let calendarError {
                Text(calendarError)
                    .foregroundStyle(.red)
            }

            if isCreatingCalendar {
                HStack {
                    TextField("Calendar name", text: $newCalendarName)
                        .textFieldStyle(.roundedBorder)
                        .disableAutocorrection(true)
                        .onSubmit { attemptCreateCalendar() }
                        .onChange(of: newCalendarName) { oldValue, newValue in
                            DeveloperMode.debugPrint(.field, "Field changed: New calendar name: \"\(oldValue)\" -> \"\(newValue)\"")
                        }
                    Button("Create") {
                        DeveloperMode.debugPrint(.click, "Button clicked: Create (calendar \"\(trimmedNewCalendarName)\")")
                        attemptCreateCalendar()
                    }
                    .disabled(isSavingCalendar || trimmedNewCalendarName.isEmpty)
                    Button("Cancel") {
                        DeveloperMode.debugPrint(.click, "Button clicked: Cancel (new-calendar flow)")
                        cancelCreatingCalendar()
                    }
                    .disabled(isSavingCalendar)
                }
            } else {
                HStack {
                    Button("New calendar") {
                        DeveloperMode.debugPrint(.click, "Button clicked: New calendar")
                        beginCreatingCalendar()
                    }
                    .disabled(isLoadingCalendars)
                    Button("Refresh calendars") {
                        DeveloperMode.debugPrint(.click, "Button clicked: Refresh calendars")
                        Task { @MainActor in
                            await loadCalendars()
                        }
                    }
                    .disabled(isLoadingCalendars)
                    // Signing out flips isAuthenticated to false, restarting the .task(id:) above,
                    // which clears the cached account and resets the section above back to the
                    // credential fields -- taking this button with it.
                    Button("Sign out") {
                        DeveloperMode.debugPrint(.click, "Button clicked: Sign out")
                        authManager.signOut()
                    }
                }
            }
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
                let name = calendars.first { $0.id == trimmed }?.summary
                DeveloperMode.debugPrint(.field, "Field changed: Calendar selection: \(appState.googleCalendarName ?? "None") -> \(name ?? "None")")
                appState.googleCalendarID = trimmed.isEmpty ? nil : trimmed
                appState.googleCalendarName = name
            }
        )
    }

    private var trimmedNewCalendarName: String {
        newCalendarName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func beginCreatingCalendar() {
        newCalendarName = Self.defaultNewCalendarName
        isCreatingCalendar = true
    }

    private func cancelCreatingCalendar() {
        isCreatingCalendar = false
        existingCalendar = nil
    }

    /// Resets the "New calendar" flow back to the New/Refresh buttons after a successful create or
    /// after picking an existing calendar.
    private func finishCreatingCalendar() {
        isCreatingCalendar = false
        existingCalendar = nil
        newCalendarName = Self.defaultNewCalendarName
    }

    private func selectCalendar(_ calendar: GoogleCalendarSummary) {
        appState.googleCalendarID = calendar.id
        appState.googleCalendarName = calendar.summary
    }

    private func attemptCreateCalendar() {
        let name = trimmedNewCalendarName
        guard !name.isEmpty, !isSavingCalendar else { return }
        Task { @MainActor in
            // The duplicate check reads the listed calendars, so list them first if that hasn't
            // happened yet -- opening the tab no longer does it. Skipping the check would create a
            // second calendar with the same name.
            if appState.googleCalendars == nil {
                await loadCalendars()
            }
            // A same-name match (case-insensitive) gets a confirmation; otherwise create outright.
            if let existing = calendars.first(where: { $0.summary.caseInsensitiveCompare(name) == .orderedSame }) {
                existingCalendar = existing
                showExistingCalendarAlert = true
                return
            }
            await createCalendar(named: name)
        }
    }

    @MainActor
    private func createCalendar(named name: String) async {
        guard !isSavingCalendar else { return }
        isSavingCalendar = true
        calendarError = nil
        defer { isSavingCalendar = false }
        do {
            let created = try await integrationCoordinator.createCalendar(named: name)
            // Refresh so the new calendar shows in the picker, then select it.
            await loadCalendars()
            selectCalendar(created)
            finishCreatingCalendar()
        } catch is CancellationError {
            // The view went away; nothing to report.
        } catch {
            calendarError = error.localizedDescription
        }
    }

    @MainActor
    private func loadAccount() async {
        guard integrationsEnabled else { return }
        // Show the cached identity immediately; only hit the userinfo endpoint on a cache miss.
        account = integrationCoordinator.cachedAccountInfo()
        do {
            if let info = try await integrationCoordinator.loadAccountInfo() {
                account = info
            }
            accountError = nil
        } catch is CancellationError {
            // The .task(id:) restarted; the replacement load reports its own result.
        } catch {
            if !Task.isCancelled && account == nil {
                accountError = "Couldn't load account details."
            }
        }
    }

    @MainActor
    private func loadCalendars() async {
        guard integrationsEnabled else { return }
        guard !isLoadingCalendars else { return }
        isLoadingCalendars = true
        calendarError = nil
        do {
            let fetched = try await integrationCoordinator.fetchCalendars()
            appState.googleCalendars = fetched.sorted { $0.summary.lowercased() < $1.summary.lowercased() }
        } catch is CancellationError {
            // The .task(id:) restarted; the replacement load reports its own errors.
        } catch {
            if !Task.isCancelled {
                calendarError = error.localizedDescription
            }
        }
        isLoadingCalendars = false
    }
}
