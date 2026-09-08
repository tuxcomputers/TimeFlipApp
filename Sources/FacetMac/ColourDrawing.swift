import AppKit
import FacetCore

extension Colour {
    /// The colour as AppKit draws it, in sRGB explicitly rather than in whatever the calibrated default is.
    ///
    /// The one direction that exists. Nothing converts an `NSColor` back: a semantic colour has no fixed components
    /// to take, so the answer would depend on the appearance in force at the moment it was asked.
    var nsColor: NSColor {
        NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }
}
