import AppKit
import FacetCore

/// What each of the menu bar's five colours is on a Mac.
///
/// **The whole of what this square holds for that capability.** `StatusItemTitle` decides which of five meanings a
/// part of the title has, in `FacetCore`, knowing nothing about how a Mac draws; this turns the answer into pixels.
/// A GTK adapter would be the same shape and a different table.
///
/// **Semantic colours, and resolved as they draw rather than here.** `NSColor.labelColor` and the four system
/// colours are not values, they are questions the appearance answers, so they come out differently in light and
/// dark and change under the app while it runs. Returning the `NSColor` itself keeps that: what is handed on is
/// still the question, and AppKit resolves it at the moment of drawing. That is why `StatusItemTitle` could never
/// have held a `Colour` of four `Double`s the way the category colours do, and why it holds a name instead.
extension StatusColour {
    var appKitColour: NSColor {
        switch self {
        case .byHand: .systemCyan
        case .cube: .systemGreen
        case .unreachable: .systemYellow
        case .spent: .systemRed
        case .ordinary: .labelColor
        }
    }
}
