import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - AppDelegate

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    var mainWindowController: MainWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 1. Boot database
        do {
            try DatabaseManager.shared.setup()
        } catch {
            fatalError("Database setup failed: \(error)")
        }

        // 2. Restore security-scoped bookmarks
        let restoredFolders = BookmarkService.shared.restoreAllFolders()

        // 3. Build main window
        mainWindowController = MainWindowController()
        mainWindowController?.showWindow(nil)

        // 4. Watch restored folders for live updates
        restoredFolders.forEach { FolderWatcher.shared.watch($0) }

        // 5. Handle folder change notifications — use reimportFolder
        // to respect tombstones (deleted files stay deleted)
        FolderWatcher.shared.onChange = { url in
            Task { await ImportService.shared.reimportFolder(url) }
        }

        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        BookmarkService.shared.stopAllAccess()
        FolderWatcher.shared.unwatchAll()
    }

    // Handle files opened from Finder
    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        let urls = filenames.map { URL(fileURLWithPath: $0) }
        Task {
            try? await ImportService.shared.importFiles(urls)
        }
    }

    // MARK: - Menu Actions

    @IBAction func openFolder(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories  = true
        panel.canChooseFiles        = false
        panel.allowsMultipleSelection = false
        panel.prompt  = "Add Folder"
        panel.message = "Choose a folder to add to your Lumina library"

        guard panel.runModal() == .OK, let url = panel.url else { return }

        Task { @MainActor in
            try? BookmarkService.shared.saveBookmark(for: url, isFolder: true)
            FolderWatcher.shared.watch(url)
            await ImportService.shared.importFolder(url)
        }
    }

    @IBAction func openFiles(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseFiles          = true
        panel.canChooseDirectories    = false
        panel.allowsMultipleSelection = true

        // Build UTType list — handle .ts and .mkv explicitly since
        // their UTTypes aren't always resolvable from extension alone
        var types: [UTType] = []
        let allExts = Array(
            MediaType.photoExtensions
                .union(MediaType.videoExtensions)
                .union(MediaType.audioExtensions)
        )
        for ext in allExts {
            if let t = UTType(filenameExtension: ext) {
                types.append(t)
            }
        }
        // Fallback: allow all if list is empty
        if types.isEmpty {
            panel.allowsOtherFileTypes = true
        } else {
            panel.allowedContentTypes = types
        }

        guard panel.runModal() == .OK else { return }
        Task {
            try? await ImportService.shared.importFiles(panel.urls)
        }
    }
}

// MARK: - LuminaApp

@main
struct LuminaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            SettingsView()
        }
    }
}

// MARK: - SettingsView

struct SettingsView: View {
    @State private var cacheSize = "Calculating…"

    var body: some View {
        Form {
            Section("Video Codec Support") {
                if FFmpegBridge.shared.isFFmpegInstalled {
                    Label("ffmpeg installed", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("MKV, AVI, WMV, FLV, WebM and other formats are supported.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Label("ffmpeg not found", systemImage: "xmark.circle.fill")
                        .foregroundStyle(.red)
                    Text("Install ffmpeg to enable support for MKV, AVI, WMV and other formats.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Install via Homebrew") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString("brew install ffmpeg", forType: .string)
                    }
                    .help("Copies 'brew install ffmpeg' to clipboard")
                }
            }

            Section("Transcode Cache") {
                HStack {
                    Text("Cache size")
                    Spacer()
                    Text(cacheSize)
                        .foregroundStyle(.secondary)
                }
                Button("Clear Cache", role: .destructive) {
                    FFmpegBridge.shared.clearCache()
                    cacheSize = FFmpegBridge.shared.cacheSizeString()
                }
                Text("Transcoded files are cached so reopening the same video is instant.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 420, height: 300)
        .onAppear {
            cacheSize = FFmpegBridge.shared.cacheSizeString()
        }
    }
}
