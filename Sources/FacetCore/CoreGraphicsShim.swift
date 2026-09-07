#if canImport(CoreGraphics)
import CoreGraphics
#else
/// `CGFloat`, on a platform with no CoreGraphics to get it from.
///
/// **The whole of what the core wanted from CoreGraphics.** Two files import it -- `SettingsMetrics` and
/// `ReportCalendarMetrics` -- and neither uses anything else in it: they are numbers a Settings tab is
/// drawn from, and the type they are written in is the one AppKit takes. `Double` is what `CGFloat` is on
/// every 64-bit Darwin platform, so this is the same type by another name rather than an approximation.
///
/// **Declared `package`, and that is not decoration.** The metrics types are `package` after the FacetCore
/// split, and a `package` member may not have an `internal` type in its signature -- a plain `typealias`
/// here trades four missing-module errors for 22 access errors reading `property cannot be declared
/// package because its type uses an internal type`, which looks nothing like a platform problem.
///
/// **One declaration for the module, not one per file.** Declaring it in both metrics files instead gives
/// `invalid redeclaration of CGFloat` and a knock-on `Equatable` failure, which is why it lives here.
package typealias CGFloat = Double
#endif
