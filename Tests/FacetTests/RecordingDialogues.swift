@testable import FacetCore
import Foundation

/// A `DialoguePresenter` that keeps what it was shown and answers with whatever the test decides.
///
/// **The second adapter, which is what makes this seam real rather than hypothetical.** `AlertPresenter` is
/// the first and a GTK one will be the third; until this existed, everything a dialogue says and offers could
/// only be checked by reading `NSAlert` calls in a Mac-only suite.
@MainActor
final class RecordingDialogues: DialoguePresenter {
    /// Every notice shown, oldest first.
    private(set) var told: [Dialogue] = []

    /// Every question asked, oldest first.
    private(set) var asked: [Dialogue] = []

    /// Which button to press, by position, for the next question. **Out of range on purpose is a real case**:
    /// it is a sheet dismissed by something other than one of our buttons, and callers have to treat that as
    /// no answer rather than guessing.
    var answersWith = 0

    /// Set to leave a question unanswered, which is what a sheet still on screen looks like.
    var leavesUnanswered = false

    func tell(_ notice: Dialogue) {
        told.append(notice)
    }

    func ask(_ question: Dialogue, answered: @escaping @MainActor (Int) -> Void) {
        asked.append(question)
        guard !leavesUnanswered else { return }
        answered(answersWith)
    }
}
