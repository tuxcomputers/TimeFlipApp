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
                        noColourName: appState.noColourName,
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
    let noColourName: String
    let onColourPicked: (Int, Int) -> Void
    @State private var selectedColor: Color
    @State private var selectedColourID: Int
    @State private var isColorPickerPresented = false

    init(
        category: CategoryRecord,
        colourOptions: [ActivityColorOption],
        noColourName: String,
        onColourPicked: @escaping (Int, Int) -> Void
    ) {
        self.category = category
        self.colourOptions = colourOptions
        self.noColourName = noColourName
        self.onColourPicked = onColourPicked
        _selectedColor = State(initialValue: category.colourHex.flatMap { ColorComponents(hex: $0)?.color } ?? .black)
        _selectedColourID = State(initialValue: category.colourID)
    }

    /// The None colour (colour_id 0) has no real hex value -- rendered as a hollow black square
    /// rather than a solid fill, so it reads as "no colour set" instead of an actual colour choice.
    private var isBlank: Bool { selectedColourID == 0 }

    var body: some View {
        HStack(spacing: SettingsLayoutConstants.FacetList.rowSpacing) {
            ActivityIconView(
                iconName: category.iconName,
                tint: .black,
                size: SettingsLayoutConstants.FacetList.iconSize
            )
            Text(category.name)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: SettingsLayoutConstants.CategoryList.nameColumnWidth, alignment: .leading)
            Button {
                DeveloperMode.debugPrint(.click, "Button clicked: Category color swatch \"\(category.name)\" (\(isColorPickerPresented ? "close" : "open") picker)")
                isColorPickerPresented.toggle()
            } label: {
                RoundedRectangle(cornerRadius: SettingsLayoutConstants.ColorPicker.rowSwatchCornerRadius)
                    .fill(isBlank ? Color.clear : selectedColor)
                    .overlay(
                        RoundedRectangle(cornerRadius: SettingsLayoutConstants.ColorPicker.rowSwatchCornerRadius)
                            .stroke(isBlank ? Color.black : Color.secondary.opacity(SettingsLayoutConstants.ColorPicker.swatchStrokeOpacity))
                    )
                    .frame(
                        width: SettingsLayoutConstants.ColorPicker.rowSwatchSize,
                        height: SettingsLayoutConstants.ColorPicker.rowSwatchSize
                    )
                    // A Color.clear fill (the hollow None-colour case) has no hit-testable area of its
                    // own -- without this, only the 1pt stroke line would register a click.
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .popover(isPresented: $isColorPickerPresented) {
                ColorOptionList(
                    selection: $selectedColor,
                    colourOptions: colourOptions,
                    onPick: { option in
                        selectedColourID = option.colourId
                        onColourPicked(category.id, option.colourId)
                    },
                    onSelect: { isColorPickerPresented = false },
                    noneOptionName: noColourName
                )
            }
            Spacer()
        }
    }
}
