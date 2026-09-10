@testable import FacetCore
import Foundation
import Testing

/// Asking somebody something, and turning what came back into a decision.
///
/// **This suite is where `choice(forButtonIndex:offering:)` went.** That function existed twice, once in
/// `CategoryRenameRules` and once in `CategoryCreateRules`, and was the same three lines of array lookup both
/// times. It existed only because an AppKit button index arrived at the surface and each rules type had to
/// translate it back. With the port there is one place that does it and no rule sees a number at all, so the
/// cases those two suites checked separately are checked once, here, against every caller.
@Suite @MainActor
struct DialogueTests {
    private enum Answer: Equatable {
        case yes
        case no
        case cancel
    }

    @Test func testAnAnswerComesBackAsTheChoiceThatWasOffered() {
        // The order on screen and the meaning of the answer are one list, so a button added in the middle
        // cannot silently repoint the others.
        let offered: [Answer] = [.yes, .no, .cancel]
        let question = Dialogue(title: "?", message: "", choices: ["Yes", "No", "Cancel"])
        let dialogues = RecordingDialogues()
        var seen: [Answer?] = []

        for position in 0..<3 {
            dialogues.answersWith = position
            dialogues.ask(question, offering: offered) { seen.append($0) }
        }

        #expect(seen == [.yes, .no, .cancel])
    }

    @Test func testTheSamePositionMeansADifferentThingWhenLessIsOffered() {
        // The case the pairing exists for. A shorter list is not the same list with the tail cut off: the
        // first button now means something else.
        let dialogues = RecordingDialogues()
        var seen: Answer?

        dialogues.answersWith = 0
        dialogues.ask(Dialogue(title: "?", message: "", choices: ["No", "Cancel"]), offering: [Answer.no, .cancel]) {
            seen = $0
        }

        #expect(seen == Answer.no)
    }

    @Test func testAnAnswerFromNoButtonOfOursIsNothing() {
        // A sheet dismissed by something else. The caller is told nothing rather than being handed a guess.
        let dialogues = RecordingDialogues()
        var seen: Answer? = .yes

        for position in [3, -1] {
            dialogues.answersWith = position
            dialogues.ask(Dialogue(title: "?", message: "", choices: ["Yes"]), offering: [Answer.yes]) { seen = $0 }
            #expect(seen == nil, "position \(position) is no button of ours")
        }
    }

    @Test func testANoticeIsNotAQuestion() {
        // Separate members rather than a question with one choice, so a notice has no completion for anybody
        // to wonder about.
        let dialogues = RecordingDialogues()

        dialogues.tell(Dialogue(title: "That did not work", message: "Try again."))

        #expect(dialogues.told.count == 1)
        #expect(dialogues.asked.isEmpty)
        #expect(dialogues.told.first?.choices.isEmpty == true, "a notice offers nothing to choose between")
    }

    // MARK: - the dialogues the rules assemble

    @Test func testTheRenameDialogueOffersItsButtonsWithTheWayOutNamed() throws {
        let asking = try #require(CategoryRenameRules.dialogue(for: .confirm(name: "Admin"), currentName: "Adm"))

        #expect(asking.title == "Rename this category?")
        #expect(asking.choices == ["Cancel", "Rename"])
        // **Named rather than inferred from the order.** AppKit relocates a button titled "Cancel" to the
        // left, so listing it first is not enough on its own: on 2026-08-16 this sheet listed
        // "Cancel | Rename anyway" and Return agreed to the rename.
        #expect(asking.wayOut == 0)
    }

    private static func category(_ name: String) -> CategoryRecord {
        CategoryRecord(
            id: 9,
            name: name,
            iconName: nil,
            colourID: 0,
            colour: nil,
            usesWhiteLines: false,
            dailyLimitMinutes: 0,
            isCategoryActive: true
        )
    }

    @Test func testTheRenameDialogueAndItsChoicesLineUp() {
        // The two lists have to be built from one source or a position means different things on each side.
        let held = Self.category("Admin")
        for decision in [
            CategoryRenameRules.Decision.confirm(name: "Admin"),
            .confirmAgainstRetired(name: "Admin", retired: [held]),
            .confirmAgainstActive(name: "Admin", activeNamesake: held),
            .refuse(activeNamesake: held),
        ] {
            let asking = CategoryRenameRules.dialogue(for: decision, currentName: "Adm")
            #expect(asking?.choices.count == CategoryRenameRules.choices(for: decision).count, "\(decision)")
        }
    }

    @Test func testNothingIsAskedWhereThereIsNothingToDecide() {
        #expect(CategoryRenameRules.dialogue(for: .ignore, currentName: "Adm") == nil)
    }

    @Test func testTheRetiredNamesakeDialogueDropsReactivateWhenThereIsMoreThanOne() {
        // With more than one there is no answer to *which* to bring back, so the button is not offered.
        let one = CategoryCreateRules.retiredNamesakeDialogue(name: "Admin", count: 1)
        let two = CategoryCreateRules.retiredNamesakeDialogue(name: "Admin", count: 2)

        #expect(one.dialogue.choices == ["Reactivate", "Create new one", "Cancel"])
        #expect(two.dialogue.choices == ["Create new one", "Cancel"])
        #expect(one.choices.count == one.dialogue.choices.count)
        #expect(two.choices.count == two.dialogue.choices.count)
    }

    @Test func testTheRetiredNamesakeDialogueNamesNoWayOut() {
        // **Preserved rather than improved.** This dialogue never set a key equivalent, so AppKit relocates
        // Cancel to the left and Return lands on "Create new one". Its siblings put Return on Cancel. Whether
        // that difference is wanted is a question for whoever owns the behaviour; the port carried it across
        // unchanged rather than deciding it.
        #expect(CategoryCreateRules.retiredNamesakeDialogue(name: "Admin", count: 1).dialogue.wayOut == nil)
    }
}
