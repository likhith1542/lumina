import SwiftUI
import UniformTypeIdentifiers

// MARK: - ViewMode

enum ViewMode: String, CaseIterable {
    case grid, list
    var systemImage: String {
        switch self {
        case .grid: return "square.grid.2x2"
        case .list: return "list.bullet"
        }
    }
}

// MARK: - MediaGrid

struct MediaGrid: View {
    let vm: LibraryViewModel
    let playback: PlaybackState

    @State private var viewMode: ViewMode = .grid
    @State private var showClearConfirm  = false
    @State private var showDeleteConfirm = false

    private let columns = [
        GridItem(.adaptive(minimum: 140, maximum: 200), spacing: 12)
    ]

    var body: some View {
        Group {
            if vm.isLoading {
                ProgressView("Loading library…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if vm.items.isEmpty {
                EmptyGridView(sidebarItem: vm.selectedSidebarItem)
            } else {
                ScrollView {
                    if viewMode == .grid {
                        LazyVGrid(columns: columns, spacing: 12) {
                            ForEach(vm.items) { item in
                                ThumbnailCell(
                                    item: item,
                                    isSelected: vm.selectedItems.contains(item.id)
                                )
                                .onTapGesture(count: 2) { openItem(item) }
                                .onTapGesture { handleTap(item) }
                                .contextMenu { contextMenu(for: item) }
                            }
                        }
                        .padding(16)
                    } else {
                        LazyVStack(spacing: 0) {
                            ForEach(vm.items) { item in
                                ListRowCell(
                                    item: item,
                                    isSelected: vm.selectedItems.contains(item.id)
                                )
                                .onTapGesture(count: 2) { openItem(item) }
                                .onTapGesture { handleTap(item) }
                                .contextMenu { contextMenu(for: item) }

                                Divider().padding(.leading, 56)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
                .safeAreaInset(edge: .bottom) {
                    if !vm.selectedItems.isEmpty {
                        SelectionActionBar(
                            count: vm.selectedItems.count,
                            onDelete: { showDeleteConfirm = true },
                            onClear:  { vm.clearSelection() }
                        )
                    }
                }
            }
        }
        .frame(minWidth: 400)
        .background(.background)
        .toolbar { gridToolbar }
        .onDrop(of: [.fileURL], isTargeted: nil, perform: handleDrop)
        .onChange(of: vm.selectedSidebarItem) { _, _ in
            Task { try? await vm.fetchItems() }
        }
        .confirmationDialog(
            "Delete \(vm.selectedItems.count) item\(vm.selectedItems.count == 1 ? "" : "s")?",
            isPresented: $showDeleteConfirm, titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) { vm.deleteItems(vm.selectedItems) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes them from your Lumina library. Original files are not deleted.")
        }
        .confirmationDialog(
            "Clear entire library?",
            isPresented: $showClearConfirm, titleVisibility: .visible
        ) {
            Button("Clear All", role: .destructive) { vm.clearLibrary() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes all items from Lumina. Original files are not deleted.")
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    var gridToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            // View mode toggle
            Picker("View", selection: $viewMode) {
                ForEach(ViewMode.allCases, id: \.self) { mode in
                    Image(systemName: mode.systemImage).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 64)
            .help("Switch between grid and list view")

            // Sort menu — shows active sort + direction
            Menu {
                Section("Sort By") {
                    ForEach(SortKey.allCases, id: \.self) { key in
                        Button {
                            if vm.sortKey == key {
                                vm.sortAscending.toggle()
                            } else {
                                vm.sortKey = key
                                vm.sortAscending = (key == .title)
                            }
                            Task { try? await vm.fetchItems() }
                        } label: {
                            if vm.sortKey == key {
                                Label(key.displayName,
                                      systemImage: vm.sortAscending ? "chevron.up" : "chevron.down")
                            } else {
                                Text(key.displayName)
                            }
                        }
                    }
                }

                Divider()

                Button {
                    vm.sortAscending.toggle()
                    Task { try? await vm.fetchItems() }
                } label: {
                    Label(vm.sortAscending ? "Ascending" : "Descending",
                          systemImage: vm.sortAscending ? "arrow.up" : "arrow.down")
                }
            } label: {
                Label(vm.sortKey.displayName,
                      systemImage: vm.sortAscending ? "arrow.up" : "arrow.down")
                    .labelStyle(.titleAndIcon)
            }
            .help("Sort: \(vm.sortKey.displayName) \(vm.sortAscending ? "↑" : "↓")")

            // Select all
            if !vm.items.isEmpty {
                Button {
                    if vm.selectedItems.count == vm.items.count {
                        vm.clearSelection()
                    } else {
                        vm.selectAll()
                    }
                } label: {
                    Image(systemName: vm.selectedItems.count == vm.items.count
                          ? "checkmark.circle.fill" : "checkmark.circle")
                }
                .help(vm.selectedItems.count == vm.items.count ? "Deselect All" : "Select All  ⌘A")
                .keyboardShortcut("a", modifiers: .command)
            }

            // More options
            Menu {
                Button("Clear Entire Library…", role: .destructive) {
                    showClearConfirm = true
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .help("More options")
        }
    }

    // MARK: - Context menu

    @ViewBuilder
    private func contextMenu(for item: MediaItem) -> some View {
        Button("Open")             { openItem(item) }
        Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }

        Divider()

        Button(item.isFavorite ? "Remove from Favorites" : "Add to Favorites") {
            vm.toggleFavorite(item)
        }

        if !vm.playlists.isEmpty {
            Menu("Add to Playlist") {
                ForEach(vm.playlists) { playlist in
                    Button(playlist.name) {
                        vm.addToPlaylist(playlistId: playlist.id, mediaId: item.id)
                    }
                }
            }
        }

        Divider()

        if vm.selectedItems.count > 1 && vm.selectedItems.contains(item.id) {
            Button("Delete \(vm.selectedItems.count) Items", role: .destructive) {
                showDeleteConfirm = true
            }
        } else {
            Button("Delete", role: .destructive) {
                vm.deleteItems([item.id])
            }
        }
    }

    // MARK: - Actions

    private func handleTap(_ item: MediaItem) {
        let isMultiSelect = NSEvent.modifierFlags.contains(.command)
        vm.select(item, addToSelection: isMultiSelect)

        guard !isMultiSelect,
              item.mediaType == .audio,
              playback.currentItem?.id != item.id
        else { return }

        let sameType = vm.items.filter { $0.mediaType == .audio }
        let index    = sameType.firstIndex(where: { $0.id == item.id }) ?? 0
        playback.loadQueue(sameType, startAt: index)
        playback.currentItem = item
    }

    private func openItem(_ item: MediaItem) {
        vm.select(item)
        let sameType = vm.items.filter { $0.mediaType == item.mediaType }
        let index    = sameType.firstIndex(where: { $0.id == item.id }) ?? 0
        playback.loadQueue(sameType, startAt: index)
        playback.currentItem = item
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        var handled = false
        for provider in providers {
            guard provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) else { continue }
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
                guard let data = item as? Data,
                      let url  = URL(dataRepresentation: data, relativeTo: nil) else { return }
                Task { try? await ImportService.shared.importFiles([url]) }
            }
            handled = true
        }
        return handled
    }
}

// MARK: - ListRowCell

struct ListRowCell: View {
    let item: MediaItem
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 12) {
            // Thumbnail / icon
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.secondary.opacity(0.12))
                    .frame(width: 40, height: 40)

                if let thumb = item.thumbnailImage {
                    Image(nsImage: thumb)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 40, height: 40)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                } else {
                    Image(systemName: item.mediaType.systemImage)
                        .font(.system(size: 16))
                        .foregroundStyle(.secondary)
                }
            }

            // Info
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.body)
                    .lineLimit(1)
                Text(item.fileExtension.uppercased() + " · " + item.fileSizeString)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            Spacer()

            // Duration
            if let dur = item.duration, dur > 0 {
                Text(dur.formatted)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            // Favorite indicator
            if item.isFavorite {
                Image(systemName: "heart.fill")
                    .font(.caption)
                    .foregroundStyle(.pink)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(isSelected ? Color.accentColor.opacity(0.15) : Color.clear)
        .contentShape(Rectangle())
    }
}

// MARK: - MediaItem helpers for list view

private extension MediaItem {
    var thumbnailImage: NSImage? {
        // Try to load cached thumbnail from disk
        guard let data = try? Data(contentsOf: thumbnailURL),
              let img  = NSImage(data: data) else { return nil }
        return img
    }

    var thumbnailURL: URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LuminaThumbs")
        return dir.appendingPathComponent(id + ".jpg")
    }

    var fileSizeString: String {
        ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file)
    }
}

// MARK: - SelectionActionBar

struct SelectionActionBar: View {
    let count: Int
    let onDelete: () -> Void
    let onClear:  () -> Void

    var body: some View {
        HStack {
            Text("\(count) selected")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
            Spacer()
            Button(role: .destructive, action: onDelete) {
                Label("Delete", systemImage: "trash")
            }
            .buttonStyle(.bordered)
            Button(action: onClear) {
                Text("Deselect")
            }
            .buttonStyle(.bordered)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.regularMaterial)
    }
}

// MARK: - EmptyGridView

struct EmptyGridView: View {
    let sidebarItem: SidebarItem

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: sidebarItem.systemImage)
                .font(.system(size: 52))
                .foregroundStyle(.tertiary)
            Text("No \(sidebarItem.title)")
                .font(.title3.weight(.medium))
                .foregroundStyle(.secondary)
            Text("Add a folder or drag files here to get started.")
                .font(.callout)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
