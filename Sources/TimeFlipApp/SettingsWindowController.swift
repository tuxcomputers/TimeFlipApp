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
        }
    }

    private func updateMinimumSize() {
        let minContentSize = NSSize(width: minimumContentWidth, height: minimumContentHeight)
        window.contentMinSize = minContentSize
        window.minSize = window.frameRect(forContentRect: NSRect(origin: .zero, size: minContentSize)).size
    }
}
