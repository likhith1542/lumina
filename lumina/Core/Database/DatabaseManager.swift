import Foundation
import GRDB

// MARK: - DatabaseManager

final class DatabaseManager {
    static let shared = DatabaseManager()

    private(set) var dbQueue: DatabaseQueue!

    private init() {}

    func setup() throws {
        let folder = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("Lumina", isDirectory: true)

        try FileManager.default.createDirectory(
            at: folder, withIntermediateDirectories: true
        )

        let dbURL = folder.appendingPathComponent("lumina.sqlite")

        var config = Configuration()
        config.label = "Lumina.DB"
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA journal_mode = WAL")
            try db.execute(sql: "PRAGMA foreign_keys = ON")
            try db.execute(sql: "PRAGMA synchronous = NORMAL")
            try db.execute(sql: "PRAGMA cache_size = -8000")
        }

        dbQueue = try DatabaseQueue(path: dbURL.path, configuration: config)
        try migrate()
    }

    // MARK: - Migrations

    private func migrate() throws {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1_initial") { db in
            try db.create(table: "media_items", ifNotExists: true) { t in
                t.column("id", .text).primaryKey()
                t.column("url", .text).notNull()
                t.column("media_type", .text).notNull()
                t.column("title", .text).notNull().defaults(to: "")
                t.column("duration", .double)
                t.column("width", .integer)
                t.column("height", .integer)
                t.column("file_size", .integer).notNull().defaults(to: 0)
                t.column("date_added", .datetime).notNull()
                t.column("date_modified", .datetime).notNull()
                t.column("is_favorite", .integer).notNull().defaults(to: 0)
                t.column("play_count", .integer).notNull().defaults(to: 0)
                t.column("last_played", .datetime)
                t.column("resume_pos", .double).notNull().defaults(to: 0)
            }

            try db.create(table: "tags", ifNotExists: true) { t in
                t.column("id", .text).primaryKey()
                t.column("name", .text).notNull().unique()
                t.column("color", .text).notNull().defaults(to: "#888888")
            }

            try db.create(table: "media_tags", ifNotExists: true) { t in
                t.column("media_id", .text)
                    .notNull()
                    .references("media_items", onDelete: .cascade)
                t.column("tag_id", .text)
                    .notNull()
                    .references("tags", onDelete: .cascade)
                t.primaryKey(["media_id", "tag_id"])
            }

            try db.create(table: "playlists", ifNotExists: true) { t in
                t.column("id", .text).primaryKey()
                t.column("name", .text).notNull()
                t.column("is_smart", .integer).notNull().defaults(to: 0)
                t.column("smart_filter", .text)
                t.column("sort_key", .text).notNull().defaults(to: "date_added")
                t.column("created_at", .datetime).notNull()
            }

            try db.create(table: "playlist_items", ifNotExists: true) { t in
                t.column("playlist_id", .text)
                    .notNull()
                    .references("playlists", onDelete: .cascade)
                t.column("media_id", .text)
                    .notNull()
                    .references("media_items", onDelete: .cascade)
                t.column("position", .integer).notNull().defaults(to: 0)
                t.primaryKey(["playlist_id", "media_id"])
            }

            try db.create(table: "bookmarks", ifNotExists: true) { t in
                t.column("id", .text).primaryKey()
                t.column("url", .text).notNull().unique()
                t.column("bookmark", .blob).notNull()
                t.column("is_folder", .integer).notNull().defaults(to: 0)
            }

            try db.create(index: "idx_media_items_type",
                          on: "media_items", columns: ["media_type"])
            try db.create(index: "idx_media_items_favorite",
                          on: "media_items", columns: ["is_favorite"])
            try db.create(index: "idx_media_items_date",
                          on: "media_items", columns: ["date_added"])
        }

        // v2: add deleted_urls table to prevent re-import of deleted items
        migrator.registerMigration("v2_deleted_urls") { db in
            try db.create(table: "deleted_urls", ifNotExists: true) { t in
                t.column("url_hash", .text).primaryKey()  // SHA256 of url.path
                t.column("url", .text).notNull()
                t.column("deleted_at", .datetime).notNull()
            }
        }

        // v3: enforce URL uniqueness — prevents duplicate rows on rapid FolderWatcher events
        migrator.registerMigration("v3_url_unique") { db in
            // Remove duplicates first, keeping the oldest entry per URL
            try db.execute(sql: """
                DELETE FROM media_items
                WHERE rowid NOT IN (
                    SELECT MIN(rowid) FROM media_items GROUP BY url
                )
            """)
            try db.create(index: "idx_media_items_url",
                          on: "media_items",
                          columns: ["url"],
                          unique: true,
                          ifNotExists: true)
        }

        try migrator.migrate(dbQueue)
    }
}
