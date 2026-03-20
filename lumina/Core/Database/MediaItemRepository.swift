import Foundation
import GRDB

// MARK: - MediaItemRepository

final class MediaItemRepository {
    private let db: DatabaseQueue

    init(db: DatabaseQueue = DatabaseManager.shared.dbQueue) {
        self.db = db
    }

    // MARK: - Insert / Upsert

    func upsert(_ item: MediaItem) throws {
        try db.write { try item.save($0) }
    }

    func upsertBatch(_ items: [MediaItem]) throws {
        try db.write { conn in
            for item in items {
                try conn.execute(sql: """
                    INSERT OR IGNORE INTO media_items
                        (id, url, media_type, title, duration, width, height,
                         file_size, date_added, date_modified,
                         is_favorite, play_count, last_played, resume_pos)
                    VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                    """,
                    arguments: [
                        item.id, item.url.path, item.mediaType.rawValue,
                        item.title, item.duration, item.width, item.height,
                        item.fileSize, item.dateAdded, item.dateModified,
                        item.isFavorite ? 1 : 0, item.playCount,
                        item.lastPlayed, item.resumePosition
                    ]
                )
                if conn.changesCount == 0 {
                    try conn.execute(sql: """
                        UPDATE media_items SET
                            title         = ?,
                            duration      = ?,
                            width         = ?,
                            height        = ?,
                            file_size     = ?,
                            date_modified = ?
                        WHERE url = ?
                        """,
                        arguments: [
                            item.title, item.duration, item.width, item.height,
                            item.fileSize, item.dateModified,
                            item.url.path
                        ]
                    )
                }
            }
        }
    }

    // MARK: - Fetch

    func fetchAll(type: MediaType? = nil,
                  sortKey: SortKey = .dateAdded,
                  ascending: Bool = false) throws -> [MediaItem] {
        try db.read { conn in
            var request = MediaItem.all()
            if let type {
                request = request.filter(MediaItem.Columns.mediaType == type.rawValue)
            }
            let col = Column(sortKey.rawValue)
            request = ascending ? request.order(col.asc) : request.order(col.desc)
            return try request.fetchAll(conn)
        }
    }

    func fetchFavorites(type: MediaType? = nil) throws -> [MediaItem] {
        try db.read { conn in
            var request = MediaItem.filter(MediaItem.Columns.isFavorite == true)
            if let type {
                request = request.filter(MediaItem.Columns.mediaType == type.rawValue)
            }
            return try request.order(MediaItem.Columns.dateAdded.desc).fetchAll(conn)
        }
    }

    func fetchRecent(limit: Int = 20) throws -> [MediaItem] {
        try db.read { conn in
            try MediaItem
                .filter(sql: "last_played IS NOT NULL")
                .order(MediaItem.Columns.lastPlayed.desc)
                .limit(limit)
                .fetchAll(conn)
        }
    }

    func search(query: String, type: MediaType? = nil) throws -> [MediaItem] {
        let pattern = "%\(query)%"
        return try db.read { conn in
            var request = MediaItem.filter(MediaItem.Columns.title.like(pattern))
            if let type {
                request = request.filter(MediaItem.Columns.mediaType == type.rawValue)
            }
            return try request.fetchAll(conn)
        }
    }

    func fetch(id: String) throws -> MediaItem? {
        try db.read { try MediaItem.fetchOne($0, key: id) }
    }

    func fetchByURL(_ url: URL) throws -> MediaItem? {
        try db.read { conn in
            try MediaItem
                .filter(MediaItem.Columns.url == url.path)
                .fetchOne(conn)
        }
    }

    func fetchByFolder(_ folderURL: URL) throws -> [MediaItem] {
        let prefix = folderURL.path + "/"
        return try db.read { conn in
            try MediaItem
                .filter(MediaItem.Columns.url.like("\(prefix)%"))
                .fetchAll(conn)
        }
    }

    func fetchForSmartFilter(_ filter: SmartFilter,
                             sortKey: SortKey = .dateAdded,
                             ascending: Bool = false) throws -> [MediaItem] {
        try db.read { conn in
            let direction = ascending ? "ASC" : "DESC"
            let sql = """
                SELECT * FROM media_items
                WHERE \(filter.sqlWhere())
                ORDER BY \(sortKey.rawValue) \(direction)
            """
            return try MediaItem.fetchAll(conn, sql: sql)
        }
    }

    // MARK: - Update

    func toggleFavorite(id: String) throws {
        try db.write { conn in
            try conn.execute(
                sql: "UPDATE media_items SET is_favorite = NOT is_favorite WHERE id = ?",
                arguments: [id]
            )
        }
    }

    func incrementPlayCount(id: String) throws {
        try db.write { conn in
            try conn.execute(
                sql: "UPDATE media_items SET play_count = play_count + 1, last_played = ? WHERE id = ?",
                arguments: [Date(), id]
            )
        }
    }

    func saveResumePosition(id: String, position: TimeInterval) throws {
        try db.write { conn in
            try conn.execute(
                sql: "UPDATE media_items SET resume_pos = ? WHERE id = ?",
                arguments: [position, id]
            )
        }
    }

    func updateMetadata(id: String,
                        duration: TimeInterval?,
                        width: Int?,
                        height: Int?,
                        fileSize: Int64) throws {
        try db.write { conn in
            try conn.execute(
                sql: "UPDATE media_items SET duration = ?, width = ?, height = ?, file_size = ? WHERE id = ?",
                arguments: [duration, width, height, fileSize, id]
            )
        }
    }

    // MARK: - Delete

    func delete(id: String) throws {
        try db.write { try MediaItem.deleteOne($0, key: id) }
    }

    func deleteBatch(ids: [String]) throws {
        try db.write { conn in
            try MediaItem.filter(ids.contains(MediaItem.Columns.id)).deleteAll(conn)
        }
    }

    func deleteAll() throws {
        try db.write { try MediaItem.deleteAll($0) }
    }

    // MARK: - Counts

    func count(type: MediaType? = nil) throws -> Int {
        try db.read { conn in
            if let type {
                return try MediaItem
                    .filter(MediaItem.Columns.mediaType == type.rawValue)
                    .fetchCount(conn)
            }
            return try MediaItem.fetchCount(conn)
        }
    }

    // MARK: - Observation

    func observeAll(type: MediaType? = nil,
                    sortKey: SortKey = .dateAdded) -> ValueObservation<ValueReducers.Fetch<[MediaItem]>> {
        ValueObservation.tracking { conn in
            var request = MediaItem.all()
            if let type {
                request = request.filter(MediaItem.Columns.mediaType == type.rawValue)
            }
            return try request.order(Column(sortKey.rawValue).desc).fetchAll(conn)
        }
    }
}

// MARK: - Deletion tombstone helpers

extension MediaItemRepository {

    /// Record a URL as intentionally deleted so ImportService never re-adds it.
    func markDeleted(url: URL) throws {
        let hash = url.path.sha256
        try db.write { conn in
            try conn.execute(
                sql: """
                    INSERT OR REPLACE INTO deleted_urls (url_hash, url, deleted_at)
                    VALUES (?, ?, ?)
                """,
                arguments: [hash, url.path, Date()]
            )
        }
    }

    func markDeletedBatch(urls: [URL]) throws {
        try db.write { conn in
            for url in urls {
                try conn.execute(
                    sql: """
                        INSERT OR REPLACE INTO deleted_urls (url_hash, url, deleted_at)
                        VALUES (?, ?, ?)
                    """,
                    arguments: [url.path.sha256, url.path, Date()]
                )
            }
        }
    }

    func isDeleted(url: URL) throws -> Bool {
        let hash = url.path.sha256
        return try db.read { conn in
            try Int.fetchOne(
                conn,
                sql: "SELECT COUNT(*) FROM deleted_urls WHERE url_hash = ?",
                arguments: [hash]
            ) ?? 0 > 0
        }
    }

    /// Clear all deletion tombstones (used by "Clear Library" to allow re-import).
    func clearDeletedURLs() throws {
        try db.write { conn in
            try conn.execute(sql: "DELETE FROM deleted_urls")
        }
    }

    /// Clear tombstones for specific URLs only — used when user explicitly
    /// re-imports a folder, so previously deleted files can come back.
    func clearDeletedURLs(forURLs urls: [URL]) throws {
        guard !urls.isEmpty else { return }
        try db.write { conn in
            for url in urls {
                try conn.execute(
                    sql: "DELETE FROM deleted_urls WHERE url_hash = ?",
                    arguments: [url.path.sha256]
                )
            }
        }
    }
}
