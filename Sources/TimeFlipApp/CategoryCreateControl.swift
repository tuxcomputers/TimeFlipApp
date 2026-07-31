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
    /// Inserts the category and returns its new `category_id`, or `nil` if the insert failed.
    let createCategory: (String) -> Int?
    let findCategory: (String) -> CategoryRecord?
    /// Reinstates a retired category the new name collided with, reporting whether it took. Taken
    /// as a closure because each tab refreshes its own list differently -- the Categories tab
    /// patches the loaded record in place so the row moves between its Active and Inactive
    /// sections, while a tab that only shows active categories has to re-read.
    ///
    /// It can be refused. Only one active category may hold a name, and the retired row's name may
    /// have been taken by an active one since it was retired.
    let reactivate: (CategoryRecord) -> Bool
    /// Called after a category has been inserted, with its new `category_id`, so the caller can
    /// pick the new row up and do anything else the tab it is on owes the new category -- the Faces
    /// tab assigns it to the face on show. `nil` when the insert failed, since there is then no row
    /// to act on, only a list worth re-reading.
    let onCreated: (Int?) -> Void

    @State private var isCreating = false
    @State private var newCategoryName = ""
    @State private var nameConflict: CategoryNameConflict?
    /// Set when a reinstate or an insert was refused by the database, which puts the reason on
    /// screen instead of the field simply closing with nothing to show for it.
    @State private var writeRefused: String?
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
            .alert(
                "That name is already in use",
                isPresented: Binding(get: { writeRefused != nil }, set: { if !$0 { writeRefused = nil } }),
                presenting: writeRefused
            ) { _ in
                Button("OK", role: .cancel) {}
            } message: { reason in
                Text(reason)
            }
    }

    @ViewBuilder
    private func conflictButtons(for conflict: CategoryNameConflict) -> some View {
        switch conflict {
        case .active:
            Button("Ok I am an idiot that needs to open my eyes", role: .cancel) {
                finishCreating()
            }
        case .inactive(let existing, let name):
            Button("Reactivate the old category") {
                DeveloperMode.debugPrint(.click, "Button clicked: Reactivate existing category \"\(existing.name)\"")
                let succeeded = reactivate(existing)
                finishCreating()
                guard !succeeded else { return }
                // Deferred a runloop turn: this alert replaces the one whose button was just
                // tapped, and SwiftUI drops a second alert raised while the first is still going
                // down.
                DispatchQueue.main.async {
                    writeRefused = """
                    "\(existing.name)" could not be reinstated, because an active category is \
                    already using that name.
                    """
                }
            }
            // The duplicate this creates is active while the one it collided with is retired, which
            // is allowed: only one *active* category may hold a name.
            Button("Create a new category with the same name") {
                DeveloperMode.debugPrint(.click, "Button clicked: Create duplicate category \"\(name)\"")
                insert(name)
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

    /// Acts on whatever `CategoryEditRules` makes of the typed name. The rule checks it against the
    /// whole `category` table, not just a loaded list, which omits the `Unassigned` sentinel. The
    /// insert itself is unguarded, so that check is the only thing standing between a typo and a
    /// second identically named category.
    private func save() {
        switch CategoryEditRules.createDecision(rawName: newCategoryName, findCategory: findCategory) {
        case .ignore:
            return
        case .insert(let name):
            DeveloperMode.debugPrint(.click, "Button clicked: Save new category \"\(name)\"")
            insert(name)
            finishCreating()
        case .conflict(let conflict):
            let existing = conflict.existing
            DeveloperMode.debugPrint(.click, "Button clicked: Save new category \"\(conflict.attemptedName)\"")
            DeveloperMode.debugPrint(.field, "Category name collision: \"\(conflict.attemptedName)\" matches category_id \(existing.id) (active=\(existing.isActive))")
            nameConflict = conflict
        }
    }

    /// Inserts and reports the outcome. A refusal here means the database saw a name the check
    /// above did not -- the check reads the table, the insert writes it, and nothing holds a lock
    /// between the two -- so it is rare rather than impossible, and it must not look like success.
    private func insert(_ name: String) {
        let newCategoryID = createCategory(name)
        onCreated(newCategoryID)
        guard newCategoryID == nil else { return }
        DeveloperMode.debugPrint(.field, "Category \"\(name)\" was not created: the insert was refused")
        // Deferred for the same reason as the reinstate case above: this can follow the collision
        // alert closing.
        DispatchQueue.main.async {
            writeRefused = """
            "\(name)" could not be created. An active category is already using that name.
            """
        }
    }

    private func finishCreating() {
        newCategoryName = ""
        isCreating = false
        nameConflict = nil
        isNameFieldFocused = false
    }
}
