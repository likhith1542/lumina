import SwiftUI

// MARK: - OnboardingView

struct OnboardingView: View {
    @State private var currentStep = 0
    let onComplete: () -> Void

    private let steps: [OnboardingStep] = [
        OnboardingStep(
            icon: "photo.stack",
            iconColor: .blue,
            title: "Welcome to Lumina",
            subtitle: "Your personal media library",
            description: "Lumina keeps all your photos, videos, and audio files organized in one beautiful place — right on your Mac.",
            tip: nil
        ),
        OnboardingStep(
            icon: "folder.badge.plus",
            iconColor: .green,
            title: "Add Your Media",
            subtitle: "Import folders or individual files",
            description: "Click the + button in the toolbar to add a folder or drag files directly into the window. Lumina watches your folders for new files automatically.",
            tip: "Tip: Add your entire Photos or Music folder for instant access to everything."
        ),
        OnboardingStep(
            icon: "square.grid.2x2",
            iconColor: .orange,
            title: "Browse & Organize",
            subtitle: "Grid or list, sorted your way",
            description: "Switch between grid and list views. Sort by name, date, duration, or play count. Use the sidebar to filter by type, favorites, or playlists.",
            tip: "Tip: Double-click any file to open it. Single-click to select."
        ),
        OnboardingStep(
            icon: "play.circle.fill",
            iconColor: .purple,
            title: "Play Everything",
            subtitle: "Built-in players for all formats",
            description: "Photos support pan and zoom. Videos have full playback controls, subtitle support, and keyboard shortcuts. Audio has an equalizer and queue.",
            tip: "Tip: Press Space to play/pause, ← → to skip 10 seconds."
        ),
        OnboardingStep(
            icon: "heart.fill",
            iconColor: .pink,
            title: "Stay Organized",
            subtitle: "Favorites, playlists & smart filters",
            description: "Mark favorites with a heart. Create playlists for your best content. Recently Played tracks everything you have opened automatically.",
            tip: "Tip: Right-click any file to add it to a playlist."
        ),
        OnboardingStep(
            icon: "trash",
            iconColor: .red,
            title: "Remove Files",
            subtitle: "Delete from your library",
            description: "Select any file and press Delete, or right-click and choose Delete. To remove multiple files at once, hold ⌘ to select them all, then delete.",
            tip: "Tip: Deleting from Lumina only removes it from the library — your original file stays safe on disk."
        ),
        OnboardingStep(
            icon: "trash.slash",
            iconColor: .orange,
            title: "Clear the Library",
            subtitle: "Start fresh anytime",
            description: "To remove everything from Lumina, click the ••• menu in the toolbar and choose Clear Entire Library. This resets your library without touching any files on disk.",
            tip: "Tip: After clearing, just add your folders again to reimport everything fresh."
        ),
    ]

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(NSColor.windowBackgroundColor), Color(NSColor.controlBackgroundColor)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                // Progress dots
                HStack(spacing: 8) {
                    ForEach(steps.indices, id: \.self) { i in
                        Capsule()
                            .fill(i == currentStep ? Color.accentColor : Color.secondary.opacity(0.25))
                            .frame(width: i == currentStep ? 24 : 8, height: 8)
                            .animation(.spring(response: 0.3), value: currentStep)
                    }
                }
                .padding(.top, 32)

                Spacer()

                // Step content
                ZStack {
                    ForEach(steps.indices, id: \.self) { i in
                        if i == currentStep {
                            StepView(step: steps[i])
                                .transition(.asymmetric(
                                    insertion: .move(edge: .trailing).combined(with: .opacity),
                                    removal:   .move(edge: .leading).combined(with: .opacity)
                                ))
                        }
                    }
                }
                .frame(maxHeight: 420)
                .clipped()

                Spacer()

                // Buttons
                HStack(spacing: 16) {
                    if currentStep > 0 {
                        Button("Back") {
                            withAnimation(.easeInOut(duration: 0.25)) { currentStep -= 1 }
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .frame(width: 80)
                    } else {
                        Color.clear.frame(width: 80)
                    }

                    Spacer()

                    if currentStep < steps.count - 1 {
                        Button("Skip") { onComplete() }
                            .buttonStyle(.plain)
                            .foregroundStyle(.tertiary)
                    }

                    Button(currentStep < steps.count - 1 ? "Next" : "Get Started") {
                        if currentStep < steps.count - 1 {
                            withAnimation(.easeInOut(duration: 0.25)) { currentStep += 1 }
                        } else {
                            onComplete()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .frame(width: 140)
                }
                .padding(.horizontal, 48)
                .padding(.bottom, 40)
            }
        }
        .frame(width: 580, height: 520)
    }
}

// MARK: - StepView

private struct StepView: View {
    let step: OnboardingStep

    var body: some View {
        VStack(spacing: 24) {
            ZStack {
                Circle()
                    .fill(step.iconColor.opacity(0.12))
                    .frame(width: 100, height: 100)
                Image(systemName: step.icon)
                    .font(.system(size: 44))
                    .foregroundStyle(step.iconColor)
            }

            VStack(spacing: 8) {
                Text(step.subtitle)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                    .textCase(.uppercase)
                    .tracking(1.2)

                Text(step.title)
                    .font(.largeTitle.weight(.bold))
                    .multilineTextAlignment(.center)

                Text(step.description)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
                    .frame(maxWidth: 400)
            }

            if let tip = step.tip {
                HStack(spacing: 10) {
                    Image(systemName: "lightbulb.fill")
                        .foregroundStyle(.yellow)
                        .font(.callout)
                    Text(tip)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Color.secondary.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .frame(maxWidth: 400)
            }
        }
        .padding(.horizontal, 40)
    }
}

// MARK: - OnboardingStep model

private struct OnboardingStep {
    let icon: String
    let iconColor: Color
    let title: String
    let subtitle: String
    let description: String
    let tip: String?
}

// MARK: - OnboardingManager

enum OnboardingManager {
    private static let key = "hasCompletedOnboarding"

    static var hasCompleted: Bool {
        get { UserDefaults.standard.bool(forKey: key) }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    static func reset() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}
