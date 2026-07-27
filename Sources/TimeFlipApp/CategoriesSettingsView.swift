import SwiftUI

struct CategoriesSettingsView: View {
    @ObservedObject var appState: AppState
    let loadCategories: () -> [CategoryRecord]
    @State private var categories: [CategoryRecord] = []

    var body: some View {
        Form {
            if categories.isEmpty {
                Text("No active categories.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(categories) { category in
                    Text(category.name)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            categories = loadCategories()
        }
    }
}
