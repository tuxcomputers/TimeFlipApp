/// Something the app has to put in front of somebody, and the answers it will accept.
///
/// **A value, not a call.** The core decides what is said and which answers there are; something outside it
/// decides what that looks like. An `NSAlert` on a Mac, a `GtkMessageDialog` under GTK, and a recorded question
/// in a test, all from the same three fields.
package struct Dialogue: Equatable {
    /// The heading. One line, and it is the question or the fact, not a category of message.
    package let title: String

    /// What it says under the heading.
    package let message: String

    /// The buttons, **in the order they should be offered**, which is a decision rather than a detail: the
    /// answer that changes nothing goes first, so it is the one arrived at by accident. Empty for a notice,
    /// which gets a single dismissal and is not asking anything.
    package let choices: [String]

    /// Whether this is a warning rather than an ordinary notice. What that looks like is the platform's.
    package let isWarning: Bool

    /// Which of `choices` is the way out: the answer that changes nothing, and the one a stray Return must
    /// land on. `nil` where every answer does something.
    ///
    /// **A position in this list, and never a platform's own numbering.** It has to be said rather than
    /// inferred, and it cost a measured bug to learn that: AppKit *relocates* a button titled "Cancel" to the
    /// left, which takes it out of the rightmost place Return fires, so putting the way out first is not
    /// enough on its own. On 2026-08-16 the rename sheet listed "Cancel | Rename anyway" and Return agreed to
    /// the rename. Naming it here is what lets each adapter do whatever its own toolkit needs.
    package let wayOut: Int?

    package init(
        title: String,
        message: String,
        choices: [String] = [],
        wayOut: Int? = nil,
        isWarning: Bool = false
    ) {
        self.title = title
        self.message = message
        self.choices = choices
        self.wayOut = wayOut
        self.isWarning = isWarning
    }
}

/// Puts a question or a notice in front of somebody and reports what came back.
///
/// **Two members, and neither of them names a button index.** `NSAlert` answers with
/// `alertFirstButtonReturn` plus an offset and GTK answers with a response id; both are the platform's own
/// numbering, and neither belongs in a rule. What crosses this arm is *which of the choices you were given*,
/// and the generic `ask` below turns even that back into the caller's own type before it reaches anything that
/// decides.
///
/// **`tell` is separate from `ask` rather than an `ask` with one choice.** A notice has no answer to wait for
/// and no path that depends on it, so a caller that had to write a completion for one would be writing a
/// completion nobody reads, which is the shape a mistake hides in.
@MainActor
package protocol DialoguePresenter: AnyObject {
    /// Says something that needs no answer.
    func tell(_ notice: Dialogue)

    /// Asks something, and answers with the position of the choice taken in `question.choices`.
    ///
    /// **Prefer the generic `ask` below**, which hands back the choice itself. This is the requirement an
    /// adapter implements; the other is what callers use.
    func ask(_ question: Dialogue, answered: @escaping @MainActor (Int) -> Void)
}

extension DialoguePresenter {
    /// Asks, and answers with the choice itself rather than a position.
    ///
    /// **This is what replaced `CategoryRenameRules.choice(forButtonIndex:offering:)` and its twin in
    /// `CategoryCreateRules`.** Both were the same three lines of array lookup, written twice because the
    /// index arrived from AppKit and each rules type had to translate it back. With the port there is one
    /// place that does it, and a rule never sees a number at all.
    ///
    /// - Parameter choices: in the same order as `question.choices`, which is what makes the positions line
    ///   up. Build both from one list rather than writing the two out separately.
    /// - Parameter answered: called with the choice taken, or `nil` for a position none of them occupies,
    ///   which is a dialogue dismissed rather than answered.
    package func ask<Choice>(
        _ question: Dialogue,
        offering choices: [Choice],
        answered: @escaping @MainActor (Choice?) -> Void
    ) {
        ask(question) { index in
            answered(choices.indices.contains(index) ? choices[index] : nil)
        }
    }
}
