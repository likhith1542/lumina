import AppKit
import SwiftUI

// MARK: - FullscreenWindowManager

final class FullscreenWindowManager {
    static let shared = FullscreenWindowManager()
    private var window: NSWindow?

    private init() {}

    func present<Content: View>(@ViewBuilder content: () -> Content) {
        dismiss()

        let screen = NSScreen.main ?? NSScreen.screens[0]

        let hosting = NSHostingController(rootView: content())
        hosting.view.frame = screen.frame

        // Use NSWindow (not NSPanel) so it properly activates and receives all mouse events
        let w = NSWindow(
            contentRect: screen.frame,
            styleMask:   [.borderless, .fullSizeContentView],
            backing:     .buffered,
            defer:       false
        )
        w.contentViewController = hosting
        w.backgroundColor       = .black
        w.isOpaque              = true
        w.level                 = .screenSaver
        w.collectionBehavior    = [.canJoinAllSpaces, .fullScreenAuxiliary]
        w.isMovable             = false
        w.acceptsMouseMovedEvents = true
        w.isReleasedWhenClosed  = false

        w.setFrame(screen.frame, display: true)
        // Make it key so buttons receive mouse events
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        window = w
    }

    func dismiss() {
        window?.close()
        window = nil
        // Restore focus to main app window
        NSApp.mainWindow?.makeKeyAndOrderFront(nil)
    }
}
