import SwiftUI

/// The create-a-category control, shared by the Categories tab and the Faces tab so both offer the
/// same thing rather than two implementations of it drifting apart. Collapsed to a single Create
/// button until it is clicked, so a tab stays a list of categories rather than a permanently open
/// form.
///
/// The name-collision handling is the reason this is shared rather than duplicated: Save has to
/// check the whole `category` table and then offer a real choice between reinstating a retired
/// category and creating a second one with the same name, which is several screens of behaviour to
/// keep in step.
struct CategoryCreateControl: View {
    /// Only for the Escape handling: while the name field is open, the window's Close button has to
    /// give up its Escape shortcut -- see `AppState.openCategoryNameFields`.
    @ObservedObject var appState: AppState
    let createCategory: (String) -> Void
    let findCategory: (String) -> CategoryRecord?
    /// Reinstates a retired category the new name collided with. Taken as a closure because each
    /// tab refreshes its own list differently -- the Categories tab patches the loaded record in
    /// place so the row moves between its Active and Inactive sections, while a tab that only shows
    /// active categories has to re-read.
    let reactivate: (CategoryRecord) -> Void
    /// Called after a category has been inserted, so the caller can pick the new row up.
    let onCreated: () -> Void

    @State private var isCreating = false
    @State private var newCategoryName = ""
    @State private var nameConflict: NameConflict?
    @FocusState private var isNameFieldFocused: Bool

    var body: some View {
        control
            .alert(
                "That category already exists",
                isPresented: Binding(get: { nameConflict != nil }, set: { if !$0 { nameConflict = nil } }),
                presenting: nameConflict
            ) { conflict in
                conflictButtons(for: conflict)
            } message: { conflict in
                Text(conflict.message)
            }
    }

    /// What a Save collided with, and everything the alert needs to describe it.
    private enum NameConflict: Identifiable {
        /// The name is already in use by a category still in the Active list -- nothing to decide,
        /// it is simply there to be found.
        case active(name: String)
        /// The name belongs to a retired category. Reinstating it keeps every historical
        /// time_entry attached to the name; creating a second one does not.
        case inactive(existing: CategoryRecord, name: String)

        var id: String {
            switch self {
            case .active(let name): return "active:\(name)"
            case .inactive(_, let name): return "inactive:\(name)"
            }
        }

        var message: String {
            switch self {
            case .active(let name):
                return """
                "\(name)" is already in the Active list. Scroll up -- it is right there.
                """
            case .inactive(_, let name):
                return """
                "\(name)" already exists but has been made inactive.

                Reactivating it keeps all of its history attached. Creating a second category \
                with the same name leaves you two rows that look identical in reports, and \
                sorting that out later is on you.
                """
            }
        }
    }

    @ViewBuilder
    private func conflictButtons(for conflict: NameConflict) -> some View {
        switch conflict {
        case .active:
            Button("Ok I am an idiot that needs to open my eyes", role: .cancel) {
                finishCreating()
            }
        case .inactive(let existing, let name):
            Button("Reactivate the old category") {
                DeveloperMode.debugPrint(.click, "Button clicked: Reactivate existing category \"\(existing.name)\"")
                reactivate(existing)
                finishCreating()
            }
            Button("Create a new category with the same name") {
                DeveloperMode.debugPrint(.click, "Button clicked: Create duplicate category \"\(name)\"")
                createCategory(name)
                onCreated()
                finishCreating()
            }
            // Not one of the two choices asked for, but without a cancel-role button there is no
            // way out of the alert except by picking one of them, and Esc does nothing.
            Button("Cancel", role: .cancel) {}
        }
    }

    @ViewBuilder
    private var control: some View {
        if isCreating {
            HStack(spacing: SettingsLayoutConstants.CategoryList.createFieldSpacing) {
                TextField("", text: $newCategoryName, prompt: Text("Category name"))
                    .textFieldStyle(.roundedBorder)
                    // TextField("", ...) is still a labelled control with an empty label, so the
                    // grouped Form reserves its label column and pushes the whole row into the
                    // trailing value column. This drops that column so the row starts at the
                    // leading edge.
                    .labelsHidden()
                    .frame(maxWidth: .infinity)
                    .multilineTextAlignment(.leading)
                    .focused($isNameFieldFocused)
                    .onAppear {
                        // Deferred a runloop turn: at onAppear the field is not yet in the
                        // window's responder chain, so focusing it synchronously is dropped.
                        DispatchQueue.main.async { isNameFieldFocused = true }
                    }
                    .onSubmit(save)
                Button("Save", action: save)
                    .disabled(normalizedNewCategoryName.isEmpty)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // Escape abandons the name rather than closing the window. Counted on appear/disappear
            // rather than set alongside isCreating, so the count follows what is actually on screen
            // through a tab switch, which tears the field's view down while leaving isCreating set.
            .onAppear { appState.categoryNameFieldAppeared() }
            .onDisappear { appState.categoryNameFieldDisappeared() }
            .onExitCommand {
                DeveloperMode.debugPrint(.field, "Escape pressed: abandoned the new category name")
                finishCreating()
            }
        } else {
            Button {
                DeveloperMode.debugPrint(.click, "Button clicked: Create category")
                newCategoryName = ""
                isCreating = true
            } label: {
                Text("Create")
            }
        }
    }

    private var normalizedNewCategoryName: String {
        ActivityLibrary.normalizeCategoryName(newCategoryName)
    }

    /// Checks the name against the whole `category` table -- not just a loaded list, which omits
    /// the `Unassigned` sentinel -- before inserting anything. The insert itself is unguarded, so
    /// this is the only thing standing between a typo and a second identically named category.
    private func save() {
        let name = normalizedNewCategoryName
        guard !name.isEmpty else { return }
        DeveloperMode.debugPrint(.click, "Button clicked: Save new category \"\(name)\"")
        if let existing = findCategory(name) {
            DeveloperMode.debugPrint(.field, "Category name collision: \"\(name)\" matches category_id \(existing.id) (active=\(existing.isActive))")
            nameConflict = existing.isActive
                ? .active(name: existing.name)
                : .inactive(existing: existing, name: name)
            return
        }
        createCategory(name)
        onCreated()
        finishCreating()
    }

    private func finishCreating() {
        newCategoryName = ""
        isCreating = false
        nameConflict = nil
        isNameFieldFocused = false
    }
}
