import AppKit
import SwiftUI

struct ReportSettingsView: View {
    @ObservedObject var appState: AppState
    @ObservedObject var authManager: GoogleAuthManager
    let integrationCoordinator: GoogleIntegrationCoordinator

    @State private var calendars: [GoogleCalendarSummary] = []
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

            dailyResetSection
        }
        .formStyle(.grouped)
        .task(id: authManager.isAuthenticated) {
            guard integrationsEnabled else { return }
            if authManager.isAuthenticated {
                await loadAccount()
                await loadCalendars()
            } else {
                calendars = []
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
                selectCalendar(calendar)
                finishCreatingCalendar()
            }
            Button("Cancel", role: .cancel) {
                // Leave the name field open so a different name can be entered.
                existingCalendar = nil
            }
        } message: { calendar in
            Text("A calendar named \"\(calendar.summary)\" already exists. Use it instead of creating a new one?")
        }
    }

    // MARK: - Daily reset

    /// AM/PM half of the 12-hour picker. The stored value stays 24-hour (`appState.dailyResetHour`);
    /// this only drives the display.
    private enum Meridiem: Hashable {
        case am, pm
    }

    @ViewBuilder private var dailyResetSection: some View {
        Section("Daily reset") {
            LabeledContent("Reset at") {
                HStack(spacing: 16) {
                    // Same stacked-chevron stepper as the Device tab's auto-pause control. Hour and
                    // AM/PM step independently -- the hour wraps 1<->12 without flipping AM/PM.
                    HStack(spacing: 4) {
                        stepArrows(up: { stepHour(1) }, down: { stepHour(-1) })
                        Text("\(Self.to12Hour(appState.dailyResetHour).hour)")
                            .monospacedDigit()
                            .frame(width: 22, alignment: .trailing)
                    }
                    HStack(spacing: 4) {
                        stepArrows(up: toggleMeridiem, down: toggleMeridiem)
                        Text(Self.to12Hour(appState.dailyResetHour).meridiem == .am ? "AM" : "PM")
                            .frame(width: 30, alignment: .leading)
                    }
                }
            }
            // Whole-hour + AM/PM is all the stepper sets, but the stored time keeps minutes so a
            // finer reset can be dialled in for testing; show the effective 24-hour time so that
            // minute is visible even though it isn't editable here.
            Text(String(format: "Each category's daily total rolls over at %02d:%02d local time.",
                        appState.dailyResetHour, appState.dailyResetMinute))
                .font(.caption)
                .foregroundStyle(.secondary)
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

    /// Steps the hour by ±1 on the 12-hour face (wrapping 12->1 / 1->12), keeping AM/PM fixed.
    private func stepHour(_ delta: Int) {
        let current = Self.to12Hour(appState.dailyResetHour)
        var hour12 = current.hour + delta
        if hour12 > 12 { hour12 = 1 }
        if hour12 < 1 { hour12 = 12 }
        appState.setDailyResetTime(
            hour: Self.to24Hour(hour12: hour12, meridiem: current.meridiem),
            minute: appState.dailyResetMinute
        )
    }

    /// Flips AM<->PM, keeping the hour on the clock face fixed.
    private func toggleMeridiem() {
        let current = Self.to12Hour(appState.dailyResetHour)
        let flipped: Meridiem = current.meridiem == .am ? .pm : .am
        appState.setDailyResetTime(
            hour: Self.to24Hour(hour12: current.hour, meridiem: flipped),
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
            // Signing out flips isAuthenticated to false, restarting the .task(id:) above, which
            // clears the cached account and resets the section back to the credential fields.
            Button("Sign out") {
                authManager.signOut()
            }
        } else {
            HStack {
                Button(authManager.isAuthenticating ? "Authenticating..." : "Google Auth") {
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

            if isCreatingCalendar {
                HStack {
                    TextField("Calendar name", text: $newCalendarName)
                        .textFieldStyle(.roundedBorder)
                        .disableAutocorrection(true)
                        .onSubmit { attemptCreateCalendar() }
                    Button("Create") {
                        attemptCreateCalendar()
                    }
                    .disabled(isSavingCalendar || trimmedNewCalendarName.isEmpty)
                    Button("Cancel") {
                        cancelCreatingCalendar()
                    }
                    .disabled(isSavingCalendar)
                }
            } else {
                HStack {
                    Button("New calendar") {
                        beginCreatingCalendar()
                    }
                    .disabled(isLoadingCalendars)
                    Button("Refresh calendars") {
                        Task { @MainActor in
                            await loadCalendars()
                        }
                    }
                    .disabled(isLoadingCalendars)
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
                appState.googleCalendarID = trimmed.isEmpty ? nil : trimmed
                appState.googleCalendarName = calendars.first { $0.id == trimmed }?.summary
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
        // Check the calendars already loaded in the picker for a same-name match (case-insensitive).
        // If one exists, ask before creating a duplicate; otherwise create it outright.
        if let existing = calendars.first(where: { $0.summary.caseInsensitiveCompare(name) == .orderedSame }) {
            existingCalendar = existing
            showExistingCalendarAlert = true
            return
        }
        Task { @MainActor in
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
            calendars = fetched.sorted { $0.summary.lowercased() < $1.summary.lowercased() }
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
