import Foundation

/// What the Categories tab does when one of its controls is used: the icon, the colour, the name, the daily limit,
/// retiring, reinstating, and creating one.
///
/// **A core module because there are two Categories tabs now**, and every decision in here was made once in
/// `SettingsWindowController` when there was only one. It is the same move `DeviceSettingWrite`, `ManualClock` and
/// `CubeReports` each made ahead of it, and for the reason `docs/state-reference.md` opens with: two copies of a
/// decision get taught something in one place and not the other, and nothing fails when they part. What is left for
/// a platform is drawing a row and reporting a gesture.
///
/// **It is a sequence rather than a rule, which is why it is a type and not a `...Rules` enum.** Each method here
/// writes, reads the write back, tells the surface to redraw, and where the cube is involved sends the colour after
/// the table has taken it -- an order that matters and that `CategoryRenameRules`, `CategoryCreateRules` and
/// `CategoryEditRules` deliberately say nothing about. Those three decide *what* to do with a typed name or a
/// clicked cell; this does it.
///
/// **Nothing here holds a category.** Every method takes the record the row was drawn from and reads the table for
/// anything else it needs -- which faces hold it, what else is called that -- because those are questions only the
/// table can answer and the answer may have moved since the row was drawn.
///
/// **What redraws is the caller's**, through `changed`: the Mac reloads a pane and Linux rebuilds a list, and both
/// are the database being read again rather than a copy being patched. `timingChanged` is the second funnel and is
/// not the same question -- it is the status item and the app's own clock, which draw from these tables too.
@MainActor
package final class CategoryEdits {
    private let categories: CategoryStore
    private let faces: FaceStore
    private let dialogues: DialoguePresenter
    private let debugLog: DebugLog?

    /// The cube's LEDs, where there is a cube. Recolouring and retiring both reach it, and neither may until the
    /// table has taken the change.
    package var faceColours: FaceColourSync?

    /// Read the lists again: something changed about what they hold or what a row of them says.
    package var changed: (@MainActor () -> Void)?

    /// What is being timed may be this category, and its name, its limit and the face it sits on are all drawn
    /// elsewhere -- the status item, the app's own clock, the limit watch. The Mac's `onTimingChanged`.
    package var timingChanged: (@MainActor () -> Void)?

    /// Starts the clock on a category, for the create controls that ask for that (the Faces tab's does, the
    /// Categories tab's does not). Handed the record **read back from the table** rather than the name typed, which
    /// is the database rule applied to the app's own insert.
    package var startTiming: (@MainActor (CategoryRecord) -> Void)?

    package init(
        categories: CategoryStore,
        faces: FaceStore,
        dialogues: DialoguePresenter,
        debugLog: DebugLog?
    ) {
        self.categories = categories
        self.faces = faces
        self.dialogues = dialogues
        self.debugLog = debugLog
    }

    // MARK: - the two cells that open a picker

    /// Stores a category's artwork, which includes clearing it: re-clicking the icon a category already has answers
    /// `0`, and that is a write like any other (see `CategoryEditRules.iconSelection`).
    package func setIcon(_ iconID: Int, on category: CategoryRecord) {
        let stored = categories.setIcon(id: category.id, iconID: iconID)
        debugLog?.record(
            .click,
            "Category \(category.name) icon -> icon_id \(iconID)\(stored ? "" : " REFUSED")"
        )
        // Read back, which is what redraws the row's icon: this changes what a row says about itself rather than a
        // value the row is already showing, so there is nothing being typed into for a reload to interrupt.
        changed?()
    }

    /// Stores a category's colour, which includes clearing it: re-clicking the colour a category already has answers
    /// `0`, and that is a write like any other (see `CategoryEditRules.colourSelection`).
    package func setColour(_ colourID: Int, on category: CategoryRecord) {
        let stored = categories.setColour(id: category.id, colourID: colourID)
        debugLog?.record(
            .click,
            "Category \(category.name) colour -> colour_id \(colourID)\(stored ? "" : " REFUSED")"
        )
        // **Every face wearing this category, and only those.** Recolouring is the one edit here that can change more
        // than one face at once, and it can equally change none -- a category on no face is a swatch in a list and
        // nothing on the cube. The faces are asked for rather than assumed, since which of them hold it is a question
        // only the table can answer.
        if stored {
            let wearing = faces.facesHolding(categoryID: category.id).map(\.face)
            faceColours?.send(faces: wearing, because: "\(category.name) was recoloured")
        }
        changed?()
    }

    // MARK: - the name

    /// Acts on a name typed into a row, which always means asking first.
    ///
    /// **Every rename is confirmed**, even to a name nothing else holds, because of what a rename does to what is
    /// already recorded: everything references a category by id, so a report covering last month will show the new
    /// name too. That is not a loss and there is nothing to backfill, but it is not necessarily expected.
    ///
    /// The decision is `CategoryRenameRules`', taken against the whole `category` table rather than either list on
    /// screen, since the name may be held by a row this tab is not showing.
    ///
    /// **Both lists come here**, the retired one included: everything that differs between them is a question about
    /// the record, and `CategoryRenameRules.decision` reads `isCategoryActive` to tell an index violation from a name
    /// the table will take.
    package func rename(_ category: CategoryRecord, to typed: String) {
        let decision = CategoryRenameRules.decision(
            rawName: typed,
            current: category,
            matching: categories.matching(name:)
        )
        let choices = CategoryRenameRules.choices(for: decision)
        guard let asking = CategoryRenameRules.dialogue(for: decision, currentName: category.name) else {
            // `.ignore`: nothing typed, or the name already reads that way. The field has closed itself, and a
            // dialogue saying nothing happened would be worse than nothing happening.
            debugLog?.record(.field, "Category \(category.name) rename ignored, nothing changed")
            return
        }
        // `nil` for the dead end, which raises the same dialogue with nothing but Cancel in it: an active category
        // holds the name, so there is something to say and nothing to decide.
        let name = renamedName(from: decision)
        debugLog?.record(
            .field,
            "Category \(category.name) rename -> \(CategoryCreateRules.normalise(typed)), asking: \(asking.title)"
        )

        // The wording, the buttons and which of them Return may land on are all `CategoryRenameRules`', in one
        // answer, so their order on screen and the meaning of the reply cannot drift apart. What this method
        // does with them is nothing.
        dialogues.ask(asking, offering: choices) { [weak self] choice in
            guard let name else {
                self?.debugLog?.record(.click, "Button clicked: Cancel, \(category.name) rename refused, name taken")
                return
            }
            self?.act(on: choice, renaming: category, to: name)
        }
    }

    /// The name a decision would write, or `nil` for one that writes nothing. The refusal carries a name too -- the
    /// one that is taken -- and it is not a name to write, which is why this asks the decision rather than the text.
    private func renamedName(from decision: CategoryRenameRules.Decision) -> String? {
        switch decision {
        case .ignore, .refuse:
            return nil
        case let .confirm(name), let .confirmAgainstRetired(name, _), let .confirmAgainstActive(name, _):
            return name
        }
    }

    private func act(
        on choice: CategoryRenameRules.Choice?,
        renaming category: CategoryRecord,
        to name: String
    ) {
        // `nil` is a response no button of ours produced -- a dialogue dismissed by something else -- and it means the
        // same as Cancel: a name was typed and nothing came of it.
        guard choice?.isRename == true else {
            debugLog?.record(.click, "Button clicked: Cancel, \(category.name) not renamed")
            return
        }
        let stored = categories.setName(id: category.id, name: name)
        debugLog?.record(
            .click,
            "Button clicked: \(choice?.buttonTitle ?? "") \(category.name) -> \(name)"
                + "\(stored ? "" : " REFUSED by the index")"
        )
        // Read back either way. A rename re-sorts the list, and a refused one leaves a row showing a name the table
        // never took.
        changed?()
        // What is being timed may be this category, and its name is on the status item.
        timingChanged?()
    }

    // MARK: - the daily limit

    /// Stores a category's daily limit.
    ///
    /// A refused write is the one case that reads the row back. The field is showing what was typed, and if the table
    /// did not take it then the screen and the database now disagree -- which is the whole thing the first rule in
    /// `CLAUDE.md` exists to prevent. Losing the field's focus is the smaller cost of the two.
    package func setDailyLimit(_ minutes: Int, on category: CategoryRecord) {
        let allowed = CategoryEditRules.dailyLimitMinutes(minutes)
        let stored = categories.setDailyLimit(id: category.id, minutes: allowed)
        debugLog?.record(
            .field,
            "Category \(category.name) daily limit -> \(allowed)min\(stored ? "" : " REFUSED")"
        )
        guard stored else {
            changed?()
            return
        }
        // **The limit just edited may be the limit the app is refusing against, and the refusal has no tick of its own
        // to notice.** `DailyLimitWatch` stands itself down when the clock stops, which is exactly what a spent limit
        // does to it, so raising the limit here is a change nothing was left watching for. The edit says so itself
        // instead: the menu bar redraws and its red clears, the dropdown's Resume comes back, and the watch re-arms if
        // there is anything to watch.
        timingChanged?()
    }

    // MARK: - retiring and bringing back

    /// Retires a category and takes it off the faces holding it.
    ///
    /// **Both, or neither.** A retired category left on a face would still be what that face is timing while being
    /// absent from every list a category can be picked from, which is a state nothing else in the app is prepared to
    /// explain. The faces are cleared after the retire rather than before, so a refused retire leaves them alone.
    ///
    /// Nothing here has to check for a locked face: `CategoryEditRules` decided that before the box was drawn, and a
    /// locked face's box is disabled, so this is not reachable for one.
    package func retire(_ category: CategoryRecord) {
        guard categories.setActive(id: category.id, false) else {
            debugLog?.record(.click, "Category \(category.name) retire REFUSED")
            return
        }
        let cleared = faces.facesHolding(categoryID: category.id).filter { faces.clear(face: $0.face) }
        debugLog?.record(
            .click,
            "Category \(category.name) retired, cleared from face(s) \(cleared.map(\.face))"
        )
        // **The cleared faces go dark**, which is the same instruction the window has just carried out on screen. A
        // face holding nothing has no colour, and `FaceColourRules` sends that as black -- leaving the old colour lit
        // would make a retired category go on showing on the cube, which is precisely what retiring it means it is
        // not. Only the faces this actually cleared: a refused clear is a face still wearing the category.
        faceColours?.send(faces: cleared.map(\.face), because: "\(category.name) was retired")
        // The list is read again because retiring changes which rows belong in it, not merely what one of them says.
        changed?()
        // The Faces tab and the status item draw from the same tables, and a face this cleared may be the one being
        // timed.
        timingChanged?()
    }

    /// Brings a retired category back, or says why it cannot come back.
    ///
    /// **The name is checked before the write.** Only one active category may hold a name, and the unique index
    /// would refuse this anyway -- but a refused write cannot say *which* category is in the way, and that is the
    /// whole of what somebody needs to hear. `CategoryEditRules` answers it against the whole table rather than
    /// against either list on screen, since the clash may be with a row this tab is not showing.
    ///
    /// The index still has the last word. If the check and the index ever disagree, the index is the one that is
    /// right, so a refusal from the write is reported too rather than assumed impossible.
    ///
    /// Nothing is put on any face by this, which is why a locked face is no bar here as it is to retiring.
    package func reinstate(_ category: CategoryRecord) {
        switch CategoryEditRules.reinstateDecision(
            for: category,
            matching: categories.matching(name: category.name)
        ) {
        case let .refuse(namesake):
            debugLog?.record(
                .click,
                "Category \(category.name) reinstate REFUSED: category_id \(namesake.id) is active under that name"
            )
            // Redrawn before the notice, so the box the click ticked goes back to unticked: it claimed something the
            // table never agreed to.
            changed?()
            // The dead end for a name an active category already holds. Wording carried over from the previous app.
            dialogues.tell(Dialogue(
                title: "That name is already in use",
                message: """
                An active category is already called "\(category.name)", so this one cannot be reinstated under that \
                name.

                Rename one of them first, then try again.
                """
            ))

        case .reinstate:
            let stored = categories.setActive(id: category.id, true)
            debugLog?.record(
                .click,
                "Category \(category.name) reinstated\(stored ? "" : " REFUSED by the index")"
            )
            // Read again either way: reinstating changes which list the row belongs in, and a refusal has to put the
            // box back.
            changed?()
        }
    }

    // MARK: - creating one, which both tabs that can do it come through

    /// Acts on a typed category name.
    ///
    /// The decision is `CategoryCreateRules`', taken against the whole `category` table rather than the list on
    /// screen -- which shows only active categories, so a retired namesake is invisible to it and the one thing
    /// standing between a typo and two identical categories would be missing.
    ///
    /// **The control that was typed into folds itself up before calling this**, which is why no control is handed
    /// over: every branch here collapsed it on the Mac, including the one that does nothing at all, so what looked
    /// like four decisions was one and it was the caller's.
    ///
    /// - Parameter startsTiming: whether the clock should start on what this produces, which is the Faces tab's
    ///   create control and not the Categories tab's.
    package func create(_ typed: String, startsTiming: Bool = false) {
        switch CategoryCreateRules.decision(rawName: typed, matching: categories.matching(name:)) {
        case .ignore:
            break

        case let .insert(name):
            let created = categories.insert(name: name)
            debugLog?.record(
                .click,
                "Button clicked: Save new category \(name) -> \(created.map { "category_id \($0)" } ?? "refused")"
            )
            // Re-read rather than adding the new row to the list by hand: the database is what the list shows, and a
            // row put there by the writer would be a second answer to what it holds.
            changed?()
            if let created { start(created, ifAskedTo: startsTiming) }

        case let .retiredNamesakes(existing):
            debugLog?.record(
                .click,
                "Button clicked: Save new category \(existing[0].name) -> asking, \(existing.count) retired "
                    + "under that name: \(existing.map(\.id))"
            )
            askAboutRetiredNamesakes(existing, startsTiming: startsTiming)

        case let .alreadyActive(existing):
            debugLog?.record(
                .click,
                "Button clicked: Save new category \(existing.name) -> already active as category_id \(existing.id)"
            )
            // The dead end: an active category already holds the name, so there is nothing to decide and only
            // something to say. Wording carried over from the previous app.
            dialogues.tell(Dialogue(
                title: "That category already exists",
                message: "\"\(existing.name)\" is already in the Active list. Scroll up -- it is right there."
            ))
        }
    }

    /// Asks what to do about a name a retired category already holds, and does it.
    ///
    /// **Three answers, because two of them are legitimate.** Bringing the old one back keeps its history, which is
    /// usually what typing a name used before means; making a new one leaves that history where it is under a name
    /// being reused deliberately, which the database allows since only *active* names are unique. Nothing in the app
    /// can tell which was meant, so it asks rather than choosing.
    ///
    /// **With more than one retired namesake the Reactivate button is not offered at all**, since there is no answer
    /// to which of them to bring back: they share a name and nothing distinguishes them on a button. The dialogue
    /// still appears, saying how many there are, and offers the answer that is still available -- creating a new one
    /// -- or nothing. Somebody who wants a particular one back goes to the Inactive list, where each row carries the
    /// date that tells them apart.
    private func askAboutRetiredNamesakes(_ existing: [CategoryRecord], startsTiming: Bool) {
        guard let first = existing.first else { return }
        let asking = CategoryCreateRules.retiredNamesakeDialogue(name: first.name, count: existing.count)
        dialogues.ask(asking.dialogue, offering: asking.choices) { [weak self] choice in
            self?.act(on: choice, about: first, named: first.name, startsTiming: startsTiming)
        }
    }

    /// **`startsTiming` reaches here too, and that is the point rather than thoroughness.** All three outcomes come
    /// from one press of one button on the Faces tab, so a name that happens to collide with a retired one would
    /// otherwise behave differently from every other name -- and which names those are is exactly what the person
    /// typing cannot know. Reinstating is included: "created" is not what they did, but it is what they got.
    private func act(
        on choice: CategoryCreateRules.RetiredNamesakeChoice?,
        about existing: CategoryRecord,
        named name: String,
        startsTiming: Bool
    ) {
        var started: Int?
        switch choice {
        case .reactivate:
            let succeeded = categories.setActive(id: existing.id, true)
            debugLog?.record(
                .click,
                "Button clicked: Reactivate \(existing.name) -> category_id \(existing.id)"
                    + "\(succeeded ? "" : " REFUSED")"
            )
            if succeeded { started = existing.id }

        case .createNew:
            let created = categories.insert(name: name)
            debugLog?.record(
                .click,
                "Button clicked: Create new one \(name) -> \(created.map { "category_id \($0)" } ?? "refused")"
                    + ", leaving category_id \(existing.id) retired"
            )
            started = created

        case .cancel, nil:
            // `nil` is a response no button of ours produced -- a dialogue dismissed by something else -- and it means
            // the same as Cancel: the name was typed and nothing came of it.
            debugLog?.record(.click, "Button clicked: Cancel, \(name) not created")
            return
        }
        // Only the two that wrote get here: either changes which rows belong in which list.
        changed?()
        if let started { start(started, ifAskedTo: startsTiming) }
    }

    /// Starts the clock on a category that has just been made, when the control that made it asks for that.
    ///
    /// **The record is read back rather than assembled from what was written**, which is the database rule applied to
    /// the app's own insert: starting needs a `CategoryRecord`, and building one here out of the name just typed would
    /// be the app's idea of the row rather than the row.
    ///
    /// A refused read leaves the category made and the clock alone. That is the honest outcome: the category exists,
    /// which is most of what was asked for, and starting a clock on a row that cannot be read back would be worse
    /// than not starting one.
    private func start(_ createdID: Int, ifAskedTo startsTiming: Bool) {
        guard startsTiming else { return }
        guard let record = categories.category(id: createdID) else {
            debugLog?.record(.mode, "Timing: category_id \(createdID) was made but could not be read back to start")
            return
        }
        startTiming?(record)
    }
}
