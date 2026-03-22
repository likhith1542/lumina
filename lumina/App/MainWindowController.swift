import AppKit
import SwiftUI

// MARK: - MainWindowController

final class MainWindowController: NSWindowController {

    init() {
        let playback = PlaybackState()

        let rootView = RootView()
            .environment(playback)
            .environmentObject(AudioEngineService.shared)

        let hostingVC = NSHostingController(rootView: rootView)

        let window = NSWindow(contentViewController: hostingVC)
        window.title = "Lumina"
        window.setContentSize(NSSize(width: 1200, height: 760))
        window.minSize   = NSSize(width: 800, height: 500)
        window.styleMask = [
            .titled, .closable, .miniaturizable,
            .resizable, .fullSizeContentView
        ]
        window.titlebarAppearsTransparent  = false
        window.isMovableByWindowBackground = false
        window.center()
        window.setFrameAutosaveName("LuminaMain")

        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) { fatalError("Use init()") }
}

// MARK: - NSWindowDelegate

extension MainWindowController: NSWindowDelegate {

    /// Called when the user clicks the red close button (window hides, app stays alive)
    func windowWillClose(_ notification: Notification) {
        pauseAllPlayback()
    }

    /// Also pause when window is miniaturised to the Dock
    func windowDidMiniaturize(_ notification: Notification) {
        pauseAllPlayback()
    }

    private func pauseAllPlayback() {
        // Pause AVPlayer (video)
        NotificationCenter.default.post(name: Constants.Notification.pausePlayback, object: nil)
        // Pause AVAudioEngine (audio)
        AudioEngineService.shared.pause()
    }
}

// MARK: - RootView

struct RootView: View {
    @State private var showOnboarding = !OnboardingManager.hasCompleted

    var body: some View {
        ContentView()
            .sheet(isPresented: $showOnboarding) {
                OnboardingView {
                    OnboardingManager.hasCompleted = true
                    showOnboarding = false
                }
                .interactiveDismissDisabled(true)
            }
    }
}
