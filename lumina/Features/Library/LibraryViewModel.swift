import Foundation
import Combine
import GRDB

// MARK: - SidebarItem

enum SidebarItem: Hashable, Identifiable {
    case allPhotos
    case allVideos
    case allAudio
    case favorites
    case recentlyPlayed
    case playlist(Playlist)
    case tag(Tag)

    var id: String {
        switch self {
        case .allPhotos:       return "all-photos"
        case .allVideos:       return "all-videos"
        case .allAudio:        return "all-audio"
        case .favorites:       return "favorites"
        case .recentlyPlayed:  return "recently-played"
        case .playlist(let p): return "playlist-\(p.id)"
        case .tag(let t):      return "tag-\(t.id)"
        }
    }

    var title: String {
        switch self {
        case .allPhotos:       return "Photos"
        case .allVideos:       return "Videos"
        case .allAudio:        return "Audio"
        case .favorites:       return "Favorites"
        case .recentlyPlayed:  return "Recently Played"
        case .playlist(let p): return p.name
        case .tag(let t):      return t.name
        }
    }

    var systemImage: String {
        switch self {
        case .allPhotos:       return "photo.on.rectangle"
        case .allVideos:       return "film.stack"
        case .allAudio:        return "music.note.list"
        case .favorites:       return "heart.fill"
        case .recentlyPlayed:  return "clock.arrow.circlepath"
        case .playlist:        return "music.note.list"
        case .tag:             return "tag.fill"
        }
    }
}

// MARK: - LibraryViewModel

@Observable
final class LibraryViewModel {
    // Sidebar
    var selectedSidebarItem: SidebarItem = .allPhotos
    var playlists: [Playlist] = []
    var tags: [Tag] = []

    // Grid
    var items: [MediaItem] = []
    var selectedItems: Set<String> = []
    var sortKey: SortKey = .dateModified
    var sortAscending = false
    var searchText = ""
    var isLoading = false

    // Import
    var importProgress: ImportProgress? = nil
    var isImporting = false

    // Error
    var errorMessage: String? = nil

    private let mediaRepo    = MediaItemRepository()
    private let playlistRepo = PlaylistRepository()
    private var observation: DatabaseCancellable?
    private var externalDeletionObserver: NSObjectProtocol?

    init() {
        Task { await load() }
        // Listen for files deleted from disk via FolderWatcher
        externalDeletionObserver = NotificationCenter.default.addObserver(
            forName: Constants.Notification.mediaItemsDeletedExternally,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self,
                  let ids = notification.userInfo?["ids"] as? Set<String> else { return }
            self.items.removeAll { ids.contains($0.id) }
            self.selectedItems.subtract(ids)
        }
    }

    deinit {
        if let observer = externalDeletionObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - Load

    @MainActor
    func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            playlists = try playlistRepo.fetchAll()
            tags      = try playlistRepo.fetchAllTags()
            try await fetchItems()
            startObservation()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    func fetchItems() async throws {
        if !searchText.isEmpty {
            items = try mediaRepo.search(query: searchText, type: mediaType(for: selectedSidebarItem))
            return
        }
        switch selectedSidebarItem {
        case .allPhotos:
            items = try mediaRepo.fetchAll(type: .photo, sortKey: sortKey, ascending: sortAscending)
        case .allVideos:
            items = try mediaRepo.fetchAll(type: .video, sortKey: sortKey, ascending: sortAscending)
        case .allAudio:
            items = try mediaRepo.fetchAll(type: .audio, sortKey: sortKey, ascending: sortAscending)
        case .favorites:
            items = try mediaRepo.fetchFavorites()
        case .recentlyPlayed:
            items = try mediaRepo.fetchRecent(limit: 50)
        case .playlist(let p):
            if p.isSmart, let filter = p.smartFilter {
                items = try mediaRepo.fetchForSmartFilter(filter, sortKey: sortKey, ascending: sortAscending)
            } else {
                items = try playlistRepo.fetchItems(playlistId: p.id)
            }
        case .tag(let t):
            // All items that have this tag via join
            items = try mediaRepo.fetchAll(sortKey: sortKey, ascending: sortAscending).filter { item in
                (try? playlistRepo.fetchTags(for: item.id).contains { $0.id == t.id }) ?? false
            }
        }
    }

    // MARK: - Live observation
    // Only observe live DB changes for the main Library sections (Photos/Videos/Audio).
    // Favorites, Recently Played, and Playlists use one-shot fetches — live observation
    // with type=nil would return all items and overwrite the filtered results.

    private func startObservation() {
        observation = nil   // cancel previous

        guard let type = mediaType(for: selectedSidebarItem) else {
            // Non-library section — no live observation needed
            return
        }

        observation = mediaRepo
            .observeAll(type: type, sortKey: sortKey)
            .start(
                in: DatabaseManager.shared.dbQueue,
                onError: { [weak self] err in
                    DispatchQueue.main.async { self?.errorMessage = err.localizedDescription }
                },
                onChange: { [weak self] updated in
                    DispatchQueue.main.async { self?.items = updated }
                }
            )
    }

    private func mediaType(for item: SidebarItem) -> MediaType? {
        switch item {
        case .allPhotos: return .photo
        case .allVideos: return .video
        case .allAudio:  return .audio
        default:         return nil
        }
    }

    // MARK: - Selection

    var selectedItem: MediaItem? {
        guard selectedItems.count == 1, let id = selectedItems.first else { return nil }
        return items.first { $0.id == id }
    }

    func select(_ item: MediaItem, addToSelection: Bool = false) {
        if addToSelection {
            if selectedItems.contains(item.id) { selectedItems.remove(item.id) }
            else { selectedItems.insert(item.id) }
        } else {
            selectedItems = [item.id]
        }
    }

    func selectAll()      { selectedItems = Set(items.map(\.id)) }
    func clearSelection() { selectedItems.removeAll() }

    // MARK: - Actions

    func toggleFavorite(_ item: MediaItem) {
        try? mediaRepo.toggleFavorite(id: item.id)
    }

    func deleteItems(_ ids: Set<String>) {
        // Collect URLs before removing (needed for tombstones)
        let urls = items.filter { ids.contains($0.id) }.map(\.url)
        // Remove from UI immediately — don't wait for DB observer
        items.removeAll { ids.contains($0.id) }
        selectedItems.subtract(ids)
        // Persist tombstones + delete from DB
        try? mediaRepo.markDeletedBatch(urls: urls)
        try? mediaRepo.deleteBatch(ids: Array(ids))
    }

    func clearLibrary() {
        // Clear tombstones too so user can re-add folders fresh after a full clear
        try? mediaRepo.clearDeletedURLs()
        try? mediaRepo.deleteAll()
        selectedItems.removeAll()
        items.removeAll()
    }

    func createPlaylist(name: String) {
        let p = Playlist.new(name: name)
        try? playlistRepo.create(p)
        playlists.append(p)
    }

    func addToPlaylist(playlistId: String, mediaId: String) {
        try? playlistRepo.addItem(playlistId: playlistId, mediaId: mediaId)
    }

    // MARK: - Sidebar change

    func sidebarItemChanged(_ item: SidebarItem) {
        selectedSidebarItem = item
        clearSelection()
        observation = nil
        Task { @MainActor in
            try? await fetchItems()
            startObservation()
        }
    }

    // MARK: - Search

    func searchChanged(_ query: String) {
        searchText = query
        Task { @MainActor in try? await fetchItems() }
    }

    // MARK: - Import

    func importFolder(_ url: URL) {
        Task { @MainActor in
            isImporting = true
            await ImportService.shared.importFolder(url)
            isImporting = false
        }
    }
}
