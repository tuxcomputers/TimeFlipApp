import Foundation

/// The question asked before a cube is wiped, and what the answers mean.
///
/// **Core because both platforms ask it**, which is the same argument `CubeNotFoundQuestion` makes: this is the
/// most destructive control the app has, and two windows wording it differently would be two different promises
/// about what is about to happen.
///
/// **The wording is the archive's**, which says exactly what goes and that it cannot be undone. It is kept whole
/// rather than tightened: somebody reading it is about to lose the cube's name, its colours and its password, and
/// the sentence that lists them is the one doing the work.
///
/// **Cancel is the way out and it is *not* first.** Every other dialogue in this app puts the harmless answer at
/// the front, because that is where an accidental press lands. Here the archive put *Reset Device* first and
/// Cancel second, and `wayOut` names the second -- so the answer a stray Return reaches is Cancel whatever order
/// they are drawn in. What a platform has to do to honour that is its own: GTK sets a default response, and AppKit
/// has to work around relocating a button titled Cancel, which `AlertPresenter` records as a measured trap.
package enum CubeResetQuestion {
    /// The answers, in the order they are offered.
    package static let answers = [true, false]

    package static let dialogue = Dialogue(
        title: "Reset this TimeFlip to factory settings?",
        message: """
        This erases everything stored on the device -- face colours, task settings, name, and password \
        -- back to factory defaults. This cannot be undone.
        """,
        choices: ["Reset Device", "Cancel"],
        wayOut: 1,
        isWarning: true
    )

    /// **What to say afterwards is not here**, and that is deliberate: `FactoryResetOutcome.message(for:)` already
    /// words all three endings, including the middle one that is the whole point -- sent and erased are different
    /// claims. A second copy of that sentence is the hazard this module exists to prevent, one level down.
}
