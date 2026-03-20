import Foundation
import GRDB

// MARK: - Tag

struct Tag: Identifiable, Hashable {
    var id: String
    var name: String
    var colorHex: String   // e.g. "#FF5733"

    static func new(name: String, colorHex: String = "#888888") -> Tag {
        Tag(id: UUID().uuidString, name: name, colorHex: colorHex)
    }
}

extension Tag: FetchableRecord, PersistableRecord {
    static var databaseTableName: String { "tags" }

    enum Columns: String, ColumnExpression {
        case id, name, color
    }

    init(row: Row) throws {
        id       = row[Columns.id]
        name     = row[Columns.name]
        colorHex = row[Columns.color] ?? "#888888"
    }

    func encode(to container: inout PersistenceContainer) throws {
        container[Columns.id]    = id
        container[Columns.name]  = name
        container[Columns.color] = colorHex
    }
}

// MARK: - MediaTag (join table)

struct MediaTag {
    var mediaId: String
    var tagId: String
}

extension MediaTag: FetchableRecord, PersistableRecord {
    static var databaseTableName: String { "media_tags" }

    enum Columns: String, ColumnExpression {
        case mediaId = "media_id", tagId = "tag_id"
    }

    init(row: Row) throws {
        mediaId = row[Columns.mediaId]
        tagId   = row[Columns.tagId]
    }

    func encode(to container: inout PersistenceContainer) throws {
        container[Columns.mediaId] = mediaId
        container[Columns.tagId]   = tagId
    }
}

// MARK: - Playlist

struct Playlist: Identifiable, Hashable {
    var id: String
    var name: String
    var isSmart: Bool
    var smartFilter: SmartFilter?  // encoded as JSON in DB
    var sortKey: SortKey
    var createdAt: Date

    static func new(name: String) -> Playlist {
        Playlist(
            id: UUID().uuidString,
            name: name,
            isSmart: false,
            smartFilter: nil,
            sortKey: .dateAdded,
            createdAt: Date()
        )
    }
}

enum SortKey: String, Codable, CaseIterable {
    case title       = "title"
    case dateAdded   = "date_added"
    case dateModified = "date_modified"
    case duration    = "duration"
    case fileSize    = "file_size"
    case playCount   = "play_count"

    var displayName: String {
        switch self {
        case .title:        return "Title"
        case .dateAdded:    return "Date Added"
        case .dateModified: return "Date Modified"
        case .duration:     return "Duration"
        case .fileSize:     return "File Size"
        case .playCount:    return "Play Count"
        }
    }
}

// MARK: - SmartFilter

struct SmartFilter: Codable, Hashable {
    var mediaTypes: [MediaType]
    var isFavorite: Bool?
    var minDuration: TimeInterval?
    var maxDuration: TimeInterval?
    var tagIds: [String]
    var searchText: String?

    func sqlWhere() -> String {
        var clauses: [String] = []
        if !mediaTypes.isEmpty {
            let types = mediaTypes.map { "'\($0.rawValue)'" }.joined(separator: ",")
            clauses.append("media_type IN (\(types))")
        }
        if let fav = isFavorite { clauses.append("is_favorite = \(fav ? 1 : 0)") }
        if let min = minDuration { clauses.append("duration >= \(min)") }
        if let max = maxDuration { clauses.append("duration <= \(max)") }
        if let q = searchText, !q.isEmpty {
            clauses.append("title LIKE '%\(q.replacingOccurrences(of: "'", with: "''"))%'")
        }
        return clauses.isEmpty ? "1" : clauses.joined(separator: " AND ")
    }
}

// MARK: - Playlist GRDB

extension Playlist: FetchableRecord, PersistableRecord {
    static var databaseTableName: String { "playlists" }

    enum Columns: String, ColumnExpression {
        case id, name, isSmart = "is_smart",
             smartFilter = "smart_filter", sortKey = "sort_key",
             createdAt = "created_at"
    }

    init(row: Row) throws {
        id        = row[Columns.id]
        name      = row[Columns.name]
        isSmart   = row[Columns.isSmart]
        sortKey   = SortKey(rawValue: row[Columns.sortKey] ?? "") ?? .dateAdded
        createdAt = row[Columns.createdAt]
        if let json = row[Columns.smartFilter] as? String,
           let data = json.data(using: .utf8) {
            smartFilter = try? JSONDecoder().decode(SmartFilter.self, from: data)
        }
    }

    func encode(to container: inout PersistenceContainer) throws {
        container[Columns.id]       = id
        container[Columns.name]     = name
        container[Columns.isSmart]  = isSmart
        container[Columns.sortKey]  = sortKey.rawValue
        container[Columns.createdAt] = createdAt
        if let f = smartFilter,
           let data = try? JSONEncoder().encode(f) {
            container[Columns.smartFilter] = String(data: data, encoding: .utf8)
        }
    }
}

// MARK: - PlaylistItem (join table)

struct PlaylistItem {
    var playlistId: String
    var mediaId: String
    var position: Int
}

extension PlaylistItem: FetchableRecord, PersistableRecord {
    static var databaseTableName: String { "playlist_items" }

    enum Columns: String, ColumnExpression {
        case playlistId = "playlist_id", mediaId = "media_id", position
    }

    init(row: Row) throws {
        playlistId = row[Columns.playlistId]
        mediaId    = row[Columns.mediaId]
        position   = row[Columns.position]
    }

    func encode(to container: inout PersistenceContainer) throws {
        container[Columns.playlistId] = playlistId
        container[Columns.mediaId]    = mediaId
        container[Columns.position]   = position
    }
}
