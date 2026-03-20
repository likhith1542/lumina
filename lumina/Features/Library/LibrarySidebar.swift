import SwiftUI

// MARK: - LibrarySidebar

struct LibrarySidebar: View {
    @Bindable var vm: LibraryViewModel
    @State private var newPlaylistName = ""
    @State private var showingNewPlaylist = false

    var body: some View {
        List(selection: Binding(
            get: { vm.selectedSidebarItem },
            set: { if let item = $0 { vm.sidebarItemChanged(item) } }
        )) {
            // MARK: Library section
            Section("Library") {
                SidebarRow(item: .allPhotos)
                SidebarRow(item: .allVideos)
                SidebarRow(item: .allAudio)
            }

            // MARK: Smart section
            Section("Smart") {
                SidebarRow(item: .favorites)
                SidebarRow(item: .recentlyPlayed)
            }

            // MARK: Playlists section
            Section {
                ForEach(vm.playlists) { playlist in
                    SidebarRow(item: .playlist(playlist))
                        .contextMenu {
                            Button("Delete Playlist", role: .destructive) {
                                try? PlaylistRepository().delete(id: playlist.id)
                                vm.playlists.removeAll { $0.id == playlist.id }
                            }
                        }
                }
            } header: {
                HStack {
                    Text("Playlists")
                    Spacer()
                    Button {
                        showingNewPlaylist = true
                    } label: {
                        Image(systemName: "plus")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .help("New Playlist")
                }
            }

            // MARK: Tags section
            if !vm.tags.isEmpty {
                Section("Tags") {
                    ForEach(vm.tags) { tag in
                        SidebarRow(item: .tag(tag))
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .frame(minWidth: 200, maxWidth: 280)
        // Prevent the List from consuming arrow keys meant for the detail panel
        .onWindowKeyPress(id: "sidebar-arrows") { event in
            // Only suppress up/down when they'd navigate the sidebar selection
            // Let them pass through so the detail panel can handle them
            return false  // never consume — just observe
        }
        .overlay(alignment: .bottom) {
            if vm.isImporting {
                ImportProgressBanner(progress: vm.importProgress)
            }
        }
        .sheet(isPresented: $showingNewPlaylist) {
            NewPlaylistSheet(name: $newPlaylistName) { name in
                vm.createPlaylist(name: name)
                newPlaylistName = ""
            }
        }
    }
}

// MARK: - SidebarRow

struct SidebarRow: View {
    let item: SidebarItem

    var body: some View {
        Label(item.title, systemImage: item.systemImage)
            .tag(item)
    }
}

// MARK: - ImportProgressBanner

struct ImportProgressBanner: View {
    let progress: ImportProgress?

    var body: some View {
        if let p = progress {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Importing…")
                        .font(.caption.weight(.medium))
                    Spacer()
                    Text("\(p.completed)/\(p.total)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ProgressView(value: p.fraction)
                    .progressViewStyle(.linear)
                Text(p.currentFile)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(10)
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .padding(8)
        }
    }
}

// MARK: - NewPlaylistSheet

struct NewPlaylistSheet: View {
    @Binding var name: String
    let onCreate: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 20) {
            Text("New Playlist")
                .font(.headline)

            TextField("Playlist Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit { submit() }

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.escape)
                Button("Create") { submit() }
                    .keyboardShortcut(.return)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 280)
        .onAppear { focused = true }
    }

    private func submit() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        onCreate(trimmed)
        dismiss()
    }
}
