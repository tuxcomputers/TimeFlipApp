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
