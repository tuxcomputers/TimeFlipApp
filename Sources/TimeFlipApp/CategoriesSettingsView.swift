import SwiftUI

struct CategoriesSettingsView: View {
    @ObservedObject var appState: AppState
    let loadCategories: () -> [CategoryRecord]
    let updateCategoryColour: (Int, Int) -> Void
    @State private var categories: [CategoryRecord] = []

    var body: some View {
        Form {
            if categories.isEmpty {
                Text("No active categories.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(categories) { category in
                    CategoryRow(
                        category: category,
                        colourOptions: appState.colourOptions,
                        onColourPicked: updateCategoryColour
                    )
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
    let colourOptions: [ActivityColorOption]
    let onColourPicked: (Int, Int) -> Void
    @State private var selectedColor: Color
    @State private var isColorPickerPresented = false

    init(category: CategoryRecord, colourOptions: [ActivityColorOption], onColourPicked: @escaping (Int, Int) -> Void) {
        self.category = category
        self.colourOptions = colourOptions
        self.onColourPicked = onColourPicked
        _selectedColor = State(initialValue: category.colourHex.flatMap { ColorComponents(hex: $0)?.color } ?? .black)
    }

    var body: some View {
        HStack(spacing: SettingsLayoutConstants.FacetList.rowSpacing) {
            ActivityIconView(
                iconName: category.iconName,
                tint: .black,
                size: SettingsLayoutConstants.FacetList.iconSize
            )
            Text(category.name)
            Button {
                DeveloperMode.debugPrint(.click, "Button clicked: Category color swatch \"\(category.name)\" (\(isColorPickerPresented ? "close" : "open") picker)")
                isColorPickerPresented.toggle()
            } label: {
                RoundedRectangle(cornerRadius: SettingsLayoutConstants.ColorPicker.rowSwatchCornerRadius)
                    .fill(selectedColor)
                    .overlay(
                        RoundedRectangle(cornerRadius: SettingsLayoutConstants.ColorPicker.rowSwatchCornerRadius)
                            .stroke(Color.secondary.opacity(SettingsLayoutConstants.ColorPicker.swatchStrokeOpacity))
                    )
                    .frame(
                        width: SettingsLayoutConstants.ColorPicker.rowSwatchSize,
                        height: SettingsLayoutConstants.ColorPicker.rowSwatchSize
                    )
            }
            .buttonStyle(.plain)
            .popover(isPresented: $isColorPickerPresented) {
                ColorOptionList(
                    selection: $selectedColor,
                    colourOptions: colourOptions,
                    onPick: { option in onColourPicked(category.id, option.colourId) }
                ) {
                    isColorPickerPresented = false
                }
            }
            Spacer()
        }
    }
}
