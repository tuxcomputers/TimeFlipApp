import SwiftUI

struct CategoriesSettingsView: View {
    @ObservedObject var appState: AppState
    let loadCategories: () -> [CategoryRecord]
    let updateCategoryColour: (Int, Int) -> Void
    @State private var categories: [CategoryRecord] = []
    // Active is the section you actually work in, so it starts open; Inactive is the archive you
    // only occasionally go looking in, so it starts folded away.
    @State private var isActiveExpanded = true
    @State private var isInactiveExpanded = false

    var body: some View {
        Form {
            CategorySection(
                title: "Active",
                isExpanded: $isActiveExpanded,
                categories: categories.filter(\.isActive),
                emptyMessage: "No active categories.",
                appState: appState,
                updateCategoryColour: updateCategoryColour
            )
            CategorySection(
                title: "Inactive",
                isExpanded: $isInactiveExpanded,
                categories: categories.filter { !$0.isActive },
                emptyMessage: "No inactive categories.",
                appState: appState,
                updateCategoryColour: updateCategoryColour
            )
        }
        .formStyle(.grouped)
        .onAppear {
            categories = loadCategories()
        }
    }
}

/// One collapsible group of categories, built like the Device tab's LED/More groups: the label is
/// a plain-styled Button that drives the same `isExpanded` binding, so clicking the text toggles
/// the group rather than only the disclosure chevron doing it.
private struct CategorySection: View {
    let title: String
    @Binding var isExpanded: Bool
    let categories: [CategoryRecord]
    let emptyMessage: String
    @ObservedObject var appState: AppState
    let updateCategoryColour: (Int, Int) -> Void

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: SettingsLayoutConstants.CategoryList.rowSpacing) {
                if categories.isEmpty {
                    Text(emptyMessage)
                        .foregroundStyle(.secondary)
                } else {
                    CategoryColumnHeaderRow()
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
            .padding(.vertical, SettingsLayoutConstants.CategoryList.sectionVerticalPadding)
        } label: {
            Button {
                DeveloperMode.debugPrint(.click, "Button clicked: \(title) categories (\(isExpanded ? "collapse" : "expand"))")
                isExpanded.toggle()
            } label: {
                Text(title)
            }
            .buttonStyle(.plain)
        }
    }
}

/// Column labels above the category list, aligned to `CategoryRow`'s own column widths so each
/// label sits directly over its column -- no label over the icon column, since there's nothing
/// meaningful to caption there.
private struct CategoryColumnHeaderRow: View {
    var body: some View {
        HStack(spacing: SettingsLayoutConstants.FacetList.rowSpacing) {
            Color.clear
                .frame(width: SettingsLayoutConstants.FacetList.iconSize, height: 1)
            Text("Name")
                .frame(width: SettingsLayoutConstants.CategoryList.nameColumnWidth, alignment: .leading)
            Text("Colour")
            Spacer()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
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
