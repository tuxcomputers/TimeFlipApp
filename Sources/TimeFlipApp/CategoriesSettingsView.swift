import SwiftUI

struct CategoriesSettingsView: View {
    @ObservedObject var appState: AppState

    var body: some View {
        Form {
            Text("Category management is coming soon.")
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }
}
