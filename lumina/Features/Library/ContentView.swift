import SwiftUI

// MARK: - ContentView

struct ContentView: View {
    @State private var libraryVM = LibraryViewModel()
    @Environment(PlaybackState.self) private var playback

    var body: some View {
        NavigationSplitView {
            LibrarySidebar(vm: libraryVM)
        } content: {
            MediaGrid(vm: libraryVM, playback: playback)
        } detail: {
            DetailView(vm: libraryVM, playback: playback)
        }
        .navigationSplitViewStyle(.balanced)
        .toolbar { ToolbarItems(vm: libraryVM) }
        .onReceive(NotificationCenter.default.publisher(
            for: Constants.Notification.openExternalFiles)
        ) { notification in
            guard let urls = notification.userInfo?["urls"] as? [URL],
                  let url  = urls.first else { return }
            openExternalFile(url: url)
        }
    }

    private func openExternalFile(url: URL) {
//        print("📂 openExternalFile: \(url.path)")
        guard let type = MediaType.detect(from: url) else {
//            print("📂 unknown media type for \(url.lastPathComponent)")
            return
        }

        let sidebarItem: SidebarItem = switch type {
            case .photo: .allPhotos
            case .video: .allVideos
            case .audio: .allAudio
        }
        libraryVM.sidebarItemChanged(sidebarItem)

        Task { @MainActor in
            // Wait for library fetch to complete
            try? await Task.sleep(nanoseconds: 600_000_000)

//            print("📂 library has \(libraryVM.items.count) items, looking for \(url.lastPathComponent)")

            // Compare by path string — more reliable than URL equality
            let item = libraryVM.items.first { $0.url.path == url.path }
                ?? libraryVM.items.first { $0.url.lastPathComponent == url.lastPathComponent }

            guard let item else {
//                print("📂 item not found in library")
                return
            }

//            print("📂 found item: \(item.title), opening")
            libraryVM.select(item)
            let sameType = libraryVM.items.filter { $0.mediaType == type }
            let index    = sameType.firstIndex(where: { $0.id == item.id }) ?? 0
            playback.loadQueue(sameType, startAt: index)
            playback.currentItem = item
        }
    }
}

// MARK: - DetailView

struct DetailView: View {
    let vm: LibraryViewModel
    let playback: PlaybackState

    var body: some View {
        if let item = vm.selectedItem {
            switch item.mediaType {
            case .photo:
                PhotoViewerView(
                    item: item,
                    vm: PhotoViewerViewModel(item: item),
                    allItems: vm.items.filter { $0.mediaType == .photo },
                    onNavigate: { navigateTo($0) }
                )
                .onTapGesture {
                    NSApp.keyWindow?.makeFirstResponder(nil)
                }
            case .video:
                VideoPlayerView(item: item, playback: playback)
                    .id(item.id)
            case .audio:
                AudioPlayerView(playback: playback, item: item)
            }
        } else {
            EmptyDetailView()
        }
    }

    private func navigateTo(_ item: MediaItem) {
        vm.select(item)
        let index = vm.items.firstIndex(where: { $0.id == item.id }) ?? 0
        playback.loadQueue(vm.items, startAt: index)
        playback.currentItem = item
    }
}

// MARK: - EmptyDetailView

struct EmptyDetailView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 56))
                .foregroundStyle(.tertiary)
            Text("Select a file to view")
                .font(.title3)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
    }
}

// MARK: - ToolbarItems

struct ToolbarItems: ToolbarContent {
    let vm: LibraryViewModel

    var body: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button {
                NSApp.sendAction(#selector(AppDelegate.openFolder(_:)), to: nil, from: nil)
            } label: {
                Label("Add Folder", systemImage: "folder.badge.plus")
            }
            .help("Add a folder to your library")
        }

        ToolbarItem(placement: .primaryAction) {
            HStack(spacing: 4) {
                Button {
                    NSApp.sendAction(#selector(AppDelegate.openFiles(_:)), to: nil, from: nil)
                } label: {
                    Image(systemName: "plus")
                }
                .help("Add files")
            }
        }

        ToolbarItem(placement: .primaryAction) {
            SearchField(text: Binding(
                get: { vm.searchText },
                set: { vm.searchChanged($0) }
            ))
            .frame(width: 200)
        }
    }
}

// MARK: - SearchField

struct SearchField: NSViewRepresentable {
    @Binding var text: String

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = "Search"
        field.delegate = context.coordinator
        return field
    }

    func updateNSView(_ nsView: NSSearchField, context: Context) {
        if nsView.stringValue != text { nsView.stringValue = text }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var parent: SearchField
        init(_ parent: SearchField) { self.parent = parent }
        func controlTextDidChange(_ obj: Notification) {
            if let field = obj.object as? NSSearchField {
                parent.text = field.stringValue
            }
        }
    }
}
