import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private let window: NSWindow
    private let appState: AppState
    private var minimumContentHeight: CGFloat
    private let minimumContentWidth: CGFloat = SettingsLayoutConstants.minimumWindowWidth

    init(appState: AppState, authManager: GoogleAuthManager, integrationCoordinator: GoogleIntegrationCoordinator) {
        let window = NSWindow(
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: SettingsLayoutConstants.defaultWindowWidth,
                height: SettingsLayoutConstants.defaultWindowHeight
            ),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        let fallbackHeight = SettingsLayoutConstants.fallbackMinimumContentHeight(
            facetCount: appState.facetMappings.count
        )
        self.window = window
        self.appState = appState
        self.minimumContentHeight = fallbackHeight
        super.init()

        // Load client secret from keychain so it displays in settings UI
        appState.loadClientSecretOnce()

        let rootView = SettingsRootView(
            appState: appState,
            authManager: authManager,
            integrationCoordinator: integrationCoordinator,
            onClose: { [weak window] in
                window?.close()
            }
        ) { [weak self] height in
            self?.updateMinimumContentHeight(height)
        }
        let hostingView = NSHostingView(rootView: rootView)
        window.title = "TimeFlip Settings"
        window.contentView = hostingView
        window.isReleasedWhenClosed = false
        window.delegate = self
        updateMinimumSize()
        window.center()
    }

    func show() {
        NSApp.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        appState.clearDiscoveredDevicesOnClose()
        appState.collapseDeviceTabDisclosures()
    }

    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        _ = sender
        let contentRect = NSRect(
            origin: .zero,
            size: NSSize(width: minimumContentWidth, height: minimumContentHeight)
        )
        let minFrameSize = window.frameRect(forContentRect: contentRect).size
        return NSSize(
            width: max(frameSize.width, minFrameSize.width),
            height: max(frameSize.height, minFrameSize.height)
        )
    }

    private func updateMinimumContentHeight(_ height: CGFloat) {
        guard height > 0 else { return }
        if height != minimumContentHeight {
            minimumContentHeight = height
            updateMinimumSize()
            growWindowToFitMinimumHeight()
        }
    }

    private func updateMinimumSize() {
        let minContentSize = NSSize(width: minimumContentWidth, height: minimumContentHeight)
        window.contentMinSize = minContentSize
        window.minSize = window.frameRect(forContentRect: NSRect(origin: .zero, size: minContentSize)).size
    }

    /// Raising `minSize` only stops the user from manually resizing *below* it -- AppKit never
    /// grows a window just because its minimum grew, so a tab that suddenly needs more height
    /// (e.g. more facets added) would keep silently scrolling its content until the user happened
    /// to drag the window taller themselves. Grows the window's actual frame to match whenever
    /// the new minimum exceeds the current size, keeping the top-left corner fixed (NSWindow's
    /// origin is its bottom-left corner, so growing downward on screen means *lowering* origin.y)
    /// so the window extends downward instead of jumping to a new position. Never shrinks the
    /// window -- only grows it, respecting a user's own choice to size it larger than the minimum.
    private func growWindowToFitMinimumHeight() {
        let currentContentHeight = window.contentRect(forFrameRect: window.frame).height
        guard minimumContentHeight > currentContentHeight else { return }
        let neededFrameHeight = window.frameRect(
            forContentRect: NSRect(origin: .zero, size: NSSize(width: minimumContentWidth, height: minimumContentHeight))
        ).height
        var frame = window.frame
        let delta = neededFrameHeight - frame.height
        frame.origin.y -= delta
        frame.size.height = neededFrameHeight
        window.setFrame(frame, display: true, animate: true)
    }
}
