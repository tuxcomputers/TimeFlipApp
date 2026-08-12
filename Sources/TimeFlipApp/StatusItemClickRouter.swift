import Foundation

/// What a click on the status item should do.
enum StatusItemClick: Equatable {
    /// The dropdown. Always reachable, in every state, because it is the only route to Quit.
    case showMenu
    /// Nothing, yet. The right half is where pause will live once there is something to pause; until
    /// then a click there is deliberately inert rather than falling through to the menu, so the
    /// halves never merge into one target and quietly stay merged.
    case ignore
}

/// Which of those a given click is, decided with none of the AppKit it is decided inside.
///
/// One rule today, and a separate type all the same. The archived implementation grew three rules as
/// nested `guard`s inside an `@objc` handler, and its own comment records the cost: reaching them
/// "needed a real status item, a real click and a real window server, so in practice they were only
/// ever verified by hand". Starting with the seam means the rules stay testable as they arrive.
enum StatusItemClickRouter {
    /// - Parameter isLeftSide: which half of the item was clicked. The caller works this out from the
    ///   event, since only it knows how wide the item currently is -- the width tracks the title, so
    ///   it changes as the display does.
    static func action(isLeftSide: Bool) -> StatusItemClick {
        isLeftSide ? .showMenu : .ignore
    }
}
