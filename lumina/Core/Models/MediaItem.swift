import Foundation
import GRDB
import UniformTypeIdentifiers

// MARK: - MediaType

enum MediaType: String, Codable, CaseIterable {
    case photo = "photo"
    case video = "video"
    case audio = "audio"

    static func detect(from url: URL) -> MediaType? {
        let ext = url.pathExtension.lowercased()

        // .ts is ambiguous — TypeScript vs MPEG-2 Transport Stream.
        // Use UTType conformance to check what the system actually thinks it is.
        if ext == "ts" {
            // Check if it conforms to a known source code type
            if let utType = UTType(filenameExtension: "ts") {
                // If it conforms to source code, it's TypeScript — skip it
                if utType.conforms(to: .sourceCode) { return nil }
                // If it conforms to audiovisual content, it's a video
                if utType.conforms(to: .audiovisualContent) { return .video }
            }
            // Default: check file size — TS source files are typically small text files
            // Video .ts files are almost always > 1MB
            let fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            return fileSize > 100_000 ? .video : nil
        }

        if Self.photoExtensions.contains(ext) { return .photo }
        if Self.videoExtensions.contains(ext) { return .video }
        if Self.audioExtensions.contains(ext) { return .audio }
        return nil
    }

    static let photoExtensions: Set<String> = [
        "jpg", "jpeg", "png", "heic", "heif", "webp", "gif",
        "tiff", "tif", "bmp", "avif",
        // RAW formats
        "raw", "nef", "cr2", "cr3", "arw", "orf", "raf",
        "rw2", "mrw", "dng", "3fr", "psd"
    ]

    static let videoExtensions: Set<String> = [
        "mp4", "mov", "m4v", "mkv", "avi", "wmv", "flv",
        "webm", "mpeg", "mpg", "mts", "m2ts",
        "vob", "ogv", "3gp", "divx"
        // Note: .ts intentionally excluded — conflicts with TypeScript source files
        // .ts video files are detected via MIME type check in detect(from:)
    ]

    // Extensions that are ONLY ever media (no ambiguity)
    static let unambiguousVideoExtensions: Set<String> = [
        "mp4", "mov", "m4v", "mkv", "avi", "wmv", "flv",
        "webm", "mpeg", "mpg", "mts", "m2ts",
        "vob", "ogv", "3gp", "divx"
    ]

    static let audioExtensions: Set<String> = [
        "mp3", "aac", "m4a", "flac", "wav", "aiff", "aif",
        "ogg", "opus", "wma", "alac", "ape", "mka", "caf"
    ]

    var systemImage: String {
        switch self {
        case .photo: return "photo"
        case .video: return "film"
        case .audio: return "music.note"
        }
    }
}

// MARK: - MediaItem

struct MediaItem: Identifiable, Hashable {
    var id: String           // UUID string
    var url: URL
    var mediaType: MediaType
    var title: String
    var duration: TimeInterval?   // seconds; nil for photos
    var width: Int?
    var height: Int?
    var fileSize: Int64
    var dateAdded: Date
    var dateModified: Date
    var isFavorite: Bool
    var playCount: Int
    var lastPlayed: Date?
    var resumePosition: TimeInterval  // seconds into the file

    // Computed
    var fileName: String { url.lastPathComponent }
    var fileExtension: String { url.pathExtension.lowercased() }

    var thumbnailCacheKey: String {
        "\(id)-\(Int(dateModified.timeIntervalSince1970))"
    }

    var formattedDuration: String? {
        guard let d = duration, d > 0 else { return nil }
        let total = Int(d)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%d:%02d", m, s)
    }

    static func new(url: URL, type: MediaType) -> MediaItem {
        // Use a stable ID derived from the URL path so the same file
        // always gets the same ID — prevents duplicates on re-import.
        let stableId = url.path.sha256
        return MediaItem(
            id: stableId,
            url: url,
            mediaType: type,
            title: url.deletingPathExtension().lastPathComponent,
            duration: nil,
            width: nil,
            height: nil,
            fileSize: 0,
            dateAdded: Date(),
            dateModified: Date(),
            isFavorite: false,
            playCount: 0,
            lastPlayed: nil,
            resumePosition: 0
        )
    }
}

// MARK: - GRDB Persistence

extension MediaItem: FetchableRecord, PersistableRecord {
    static var databaseTableName: String { "media_items" }

    enum Columns: String, ColumnExpression {
        case id, url, mediaType = "media_type", title, duration,
             width, height, fileSize = "file_size",
             dateAdded = "date_added", dateModified = "date_modified",
             isFavorite = "is_favorite", playCount = "play_count",
             lastPlayed = "last_played", resumePosition = "resume_pos"
    }

    init(row: Row) throws {
        id           = row[Columns.id]
        let urlStr   = row[Columns.url] as String
        url          = URL(fileURLWithPath: urlStr)
        let typeRaw  = row[Columns.mediaType] as String
        mediaType    = MediaType(rawValue: typeRaw) ?? .photo
        title        = row[Columns.title]
        duration     = row[Columns.duration]
        width        = row[Columns.width]
        height       = row[Columns.height]
        fileSize     = row[Columns.fileSize]
        dateAdded    = row[Columns.dateAdded]
        dateModified = row[Columns.dateModified]
        isFavorite   = row[Columns.isFavorite]
        playCount    = row[Columns.playCount]
        lastPlayed   = row[Columns.lastPlayed]
        resumePosition = row[Columns.resumePosition]
    }

    func encode(to container: inout PersistenceContainer) throws {
        container[Columns.id]            = id
        container[Columns.url]           = url.path
        container[Columns.mediaType]     = mediaType.rawValue
        container[Columns.title]         = title
        container[Columns.duration]      = duration
        container[Columns.width]         = width
        container[Columns.height]        = height
        container[Columns.fileSize]      = fileSize
        container[Columns.dateAdded]     = dateAdded
        container[Columns.dateModified]  = dateModified
        container[Columns.isFavorite]    = isFavorite
        container[Columns.playCount]     = playCount
        container[Columns.lastPlayed]    = lastPlayed
        container[Columns.resumePosition] = resumePosition
    }
}
