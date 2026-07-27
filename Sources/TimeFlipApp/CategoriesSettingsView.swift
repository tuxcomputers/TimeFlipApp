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
                    CategoryRow(category: category)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            categories = loadCategories()
        }
    }
}

private struct CategoryRow: View {
    let category: CategoryRecord

    var body: some View {
        HStack(spacing: SettingsLayoutConstants.FacetList.rowSpacing) {
            ActivityIconView(
                iconName: category.iconName,
                tint: .black,
                size: SettingsLayoutConstants.FacetList.iconSize
            )
            Text(category.name)
            Spacer()
            RoundedRectangle(cornerRadius: SettingsLayoutConstants.ColorPicker.rowSwatchCornerRadius)
                .fill(colour)
                .overlay(
                    RoundedRectangle(cornerRadius: SettingsLayoutConstants.ColorPicker.rowSwatchCornerRadius)
                        .stroke(Color.secondary.opacity(SettingsLayoutConstants.ColorPicker.swatchStrokeOpacity))
                )
                .frame(
                    width: SettingsLayoutConstants.ColorPicker.rowSwatchSize,
                    height: SettingsLayoutConstants.ColorPicker.rowSwatchSize
                )
        }
    }

    /// `.clear` for the `blank` colour (`colourHex == nil`) -- the stroke above still outlines the
    /// square so it reads as "no colour set" rather than an invisible gap.
    private var colour: Color {
        category.colourHex.flatMap { ColorComponents(hex: $0)?.color } ?? .clear
    }
}
