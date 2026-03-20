import Foundation
import GRDB

// MARK: - PlaylistRepository

final class PlaylistRepository {
    private let db: DatabaseQueue

    init(db: DatabaseQueue = DatabaseManager.shared.dbQueue) {
        self.db = db
    }

    // MARK: - Playlists

    func fetchAll() throws -> [Playlist] {
        try db.read { try Playlist.order(Playlist.Columns.createdAt.asc).fetchAll($0) }
    }

    func create(_ playlist: Playlist) throws {
        try db.write { try playlist.insert($0) }
    }

    func update(_ playlist: Playlist) throws {
        try db.write { try playlist.update($0) }
    }

    func delete(id: String) throws {
        try db.write { try Playlist.deleteOne($0, key: id) }
    }

    // MARK: - Playlist Items

    func fetchItems(playlistId: String) throws -> [MediaItem] {
        try db.read { conn in
            let sql = """
                SELECT m.* FROM media_items m
                INNER JOIN playlist_items pi ON pi.media_id = m.id
                WHERE pi.playlist_id = ?
                ORDER BY pi.position ASC
            """
            return try MediaItem.fetchAll(conn, sql: sql, arguments: [playlistId])
        }
    }

    func addItem(playlistId: String, mediaId: String) throws {
        try db.write { conn in
            let maxPos = try Int.fetchOne(conn, sql: """
                SELECT MAX(position) FROM playlist_items WHERE playlist_id = ?
            """, arguments: [playlistId]) ?? -1
            let item = PlaylistItem(
                playlistId: playlistId,
                mediaId: mediaId,
                position: maxPos + 1
            )
            try item.insert(conn)
        }
    }

    func removeItem(playlistId: String, mediaId: String) throws {
        try db.write { conn in
            try conn.execute(
                sql: "DELETE FROM playlist_items WHERE playlist_id = ? AND media_id = ?",
                arguments: [playlistId, mediaId]
            )
        }
    }

    func reorderItems(playlistId: String, orderedMediaIds: [String]) throws {
        try db.write { conn in
            for (index, mediaId) in orderedMediaIds.enumerated() {
                try conn.execute(
                    sql: "UPDATE playlist_items SET position = ? WHERE playlist_id = ? AND media_id = ?",
                    arguments: [index, playlistId, mediaId]
                )
            }
        }
    }

    // MARK: - Tags

    func fetchAllTags() throws -> [Tag] {
        try db.read { try Tag.order(Tag.Columns.name.asc).fetchAll($0) }
    }

    func createTag(_ tag: Tag) throws {
        try db.write { try tag.insert($0) }
    }

    func deleteTag(id: String) throws {
        try db.write { try Tag.deleteOne($0, key: id) }
    }

    func fetchTags(for mediaId: String) throws -> [Tag] {
        try db.read { conn in
            let sql = """
                SELECT t.* FROM tags t
                INNER JOIN media_tags mt ON mt.tag_id = t.id
                WHERE mt.media_id = ?
                ORDER BY t.name ASC
            """
            return try Tag.fetchAll(conn, sql: sql, arguments: [mediaId])
        }
    }

    func addTag(tagId: String, to mediaId: String) throws {
        try db.write { conn in
            let mt = MediaTag(mediaId: mediaId, tagId: tagId)
            try mt.save(conn)
        }
    }

    func removeTag(tagId: String, from mediaId: String) throws {
        try db.write { conn in
            try conn.execute(
                sql: "DELETE FROM media_tags WHERE media_id = ? AND tag_id = ?",
                arguments: [mediaId, tagId]
            )
        }
    }
}
