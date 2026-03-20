import Foundation
import AVFoundation
import ImageIO

// MARK: - ImportProgress

struct ImportProgress {
    var total:       Int
    var completed:   Int
    var currentFile: String
    var failed:      Int

    var fraction: Double {
        guard total > 0 else { return 0 }
        return Double(completed) / Double(total)
    }
}

// MARK: - ImportService

@MainActor
final class ImportService {
    static let shared = ImportService()

    private let repo        = MediaItemRepository()
    private let metaService = MetadataService()

    var progress:   ImportProgress? = nil
    var isImporting = false

    private init() {}

    // MARK: - User-triggered folder import
    // Called when user explicitly adds a folder via the UI.
    // Clears tombstones for files in this folder so they come back.

    func importFolder(_ folderURL: URL) async {
        isImporting = true
        defer { isImporting = false; progress = nil }

        let urls = collectMediaURLs(in: folderURL)
        guard !urls.isEmpty else { return }

        // Clear tombstones for all URLs in this folder —
        // user explicitly asked to import, so respect that intent.
        try? repo.clearDeletedURLs(forURLs: urls)

        progress = ImportProgress(total: urls.count, completed: 0,
                                  currentFile: "", failed: 0)

        let chunks = urls.chunked(into: 20)
        for chunk in chunks {
            // respectTombstones = false: user explicitly importing
            await processChunk(chunk, respectTombstones: false)
        }
    }

    // MARK: - Background folder re-scan (FolderWatcher)
    // Called automatically when folder contents change.
    // Respects tombstones — deleted files stay deleted.
    // Also purges DB entries whose files no longer exist on disk.

    func reimportFolder(_ folderURL: URL) async {
        let urls = collectMediaURLs(in: folderURL)
        let urlSet = Set(urls.map { $0.path })

        // Remove DB entries for files that no longer exist in this folder
        if let existing = try? repo.fetchByFolder(folderURL) {
            let missing = existing.filter { !FileManager.default.fileExists(atPath: $0.url.path) }
            if !missing.isEmpty {
                let missingIds = Set(missing.map(\.id))
                DispatchQueue.main.async {
                    NotificationCenter.default.post(
                        name: Constants.Notification.mediaItemsDeletedExternally,
                        object: nil,
                        userInfo: ["ids": missingIds]
                    )
                }
                try? repo.deleteBatch(ids: Array(missingIds))
            }
        }

        guard !urls.isEmpty else { return }
        let chunks = urls.chunked(into: 20)
        for chunk in chunks {
            await processChunk(chunk, respectTombstones: true)
        }
    }

    // MARK: - Import individual files (drag & drop)

    func importFiles(_ urls: [URL]) async throws {
        var items: [MediaItem] = []
        for url in urls {
            guard let type = MediaType.detect(from: url) else { continue }
            // For explicit drag-and-drop, clear tombstone and re-add
            try? repo.clearDeletedURLs(forURLs: [url])
            if let existing = try? repo.fetchByURL(url) {
                // Already exists — update metadata but preserve favorites/playcounts
                var updated = existing
                updated = await metaService.enrich(updated)
                items.append(updated)
            } else {
                var item = MediaItem.new(url: url, type: type)
                item = await metaService.enrich(item)
                items.append(item)
            }
        }
        try repo.upsertBatch(items)
    }

    // MARK: - Private

    private func collectMediaURLs(in folder: URL) -> [URL] {
        let allExts = MediaType.photoExtensions
            .union(MediaType.videoExtensions)
            .union(MediaType.audioExtensions)

        guard let enumerator = FileManager.default.enumerator(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey, .isHiddenKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        return enumerator.compactMap { $0 as? URL }.filter {
            guard allExts.contains($0.pathExtension.lowercased()) else { return false }
            guard MediaType.detect(from: $0) != nil else { return false }
            return true
        }
    }

    private func processChunk(_ urls: [URL], respectTombstones: Bool) async {
        var batch: [MediaItem] = []

        for url in urls {
            guard let type = MediaType.detect(from: url) else { continue }

            // Only skip tombstoned files during background re-scans
            if respectTombstones,
               (try? repo.isDeleted(url: url)) == true {
                continue
            }

            // If already in DB with same modification date — skip (no changes)
            if let existing = try? repo.fetchByURL(url) {
                let modDate = url.contentModificationDate
                if existing.dateModified == modDate { continue }

                // File was modified — update metadata, preserve user data
                var updated = existing
                updated = await metaService.enrich(updated)
                batch.append(updated)
                progress?.completed += 1
                progress?.currentFile = url.lastPathComponent
                continue
            }

            // New file — create and enrich
            var item = MediaItem.new(url: url, type: type)
            item = await metaService.enrich(item)
            batch.append(item)

            progress?.completed += 1
            progress?.currentFile = url.lastPathComponent
        }

        if !batch.isEmpty {
            try? repo.upsertBatch(batch)
        }
    }
}

// MARK: - MetadataService

final class MetadataService {
    static let shared = MetadataService()

    func enrich(_ item: MediaItem) async -> MediaItem {
        var item = item

        if let attrs = try? FileManager.default.attributesOfItem(atPath: item.url.path) {
            item.fileSize     = attrs[.size] as? Int64 ?? 0
            item.dateModified = attrs[.modificationDate] as? Date ?? Date()
        }

        switch item.mediaType {
        case .photo:           enrichPhoto(&item)
        case .video, .audio:   await enrichAV(&item)
        }

        return item
    }

    private func enrichPhoto(_ item: inout MediaItem) {
        guard let src   = CGImageSourceCreateWithURL(item.url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        else { return }
        item.width  = props[kCGImagePropertyPixelWidth]  as? Int
        item.height = props[kCGImagePropertyPixelHeight] as? Int
    }

    private func enrichAV(_ item: inout MediaItem) async {
        let asset = AVURLAsset(url: item.url)
        guard let duration = try? await asset.load(.duration) else { return }
        item.duration = duration.seconds

        if item.mediaType == .video {
            if let tracks = try? await asset.loadTracks(withMediaType: .video),
               let track  = tracks.first,
               let size   = try? await track.load(.naturalSize) {
                let transform   = (try? await track.load(.preferredTransform)) ?? .identity
                let transformed = size.applying(transform)
                item.width  = Int(abs(transformed.width))
                item.height = Int(abs(transformed.height))
            }
        }
    }
}

// MARK: - Array chunking

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
