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
    }

    required init?(coder: NSCoder) { fatalError("Use init()") }
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
