import AppKit

/// Hosts a view in a window that is never shown, for tests that click something.
///
/// `performClick` needs a window: without one it does nothing at all, silently, and a click test passes or
/// fails depending on whether some *other* test in the same run happened to make a window first. That is
/// exactly the kind of order-dependence that makes a suite untrustworthy, so a click test brings its own
/// window rather than borrowing one by luck.
///
/// Never ordered front, so nothing appears on screen.
@MainActor
enum OffscreenWindow {
    /// Puts `view` in a window and returns it. **Keep the returned window alive** for as long as the test
    /// needs the view: releasing it takes the view's window away again.
    static func host(_ view: NSView, width: CGFloat = 480, height: CGFloat = 600) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        view.frame = window.contentView?.bounds ?? .zero
        window.contentView?.addSubview(view)
        view.layoutSubtreeIfNeeded()
        return window
    }
}
