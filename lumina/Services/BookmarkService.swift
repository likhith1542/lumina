import Foundation
import GRDB

// MARK: - BookmarkRecord

private struct BookmarkRecord: FetchableRecord, PersistableRecord {
    static var databaseTableName: String { "bookmarks" }
    var id: String
    var url: String
    var bookmark: Data
    var isFolder: Bool

    init(row: Row) throws {
        id       = row["id"]
        url      = row["url"]
        bookmark = row["bookmark"]
        isFolder = row["is_folder"]
    }

    func encode(to container: inout PersistenceContainer) throws {
        container["id"]        = id
        container["url"]       = url
        container["bookmark"]  = bookmark
        container["is_folder"] = isFolder
    }
}

// MARK: - BookmarkService

/// Manages Security-Scoped Bookmarks so sandboxed app retains
/// access to user-chosen folders across launches.
final class BookmarkService {
    static let shared = BookmarkService()

    private var activeAccess: [URL: Bool] = [:]  // URL -> isStarted
    private let db: DatabaseQueue

    private init(db: DatabaseQueue = DatabaseManager.shared.dbQueue) {
        self.db = db
    }

    // MARK: - Save bookmark for a URL

    func saveBookmark(for url: URL, isFolder: Bool) throws {
        let data = try url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        try db.write { conn in
            try conn.execute(sql: """
                INSERT OR REPLACE INTO bookmarks (id, url, bookmark, is_folder)
                VALUES (?, ?, ?, ?)
            """, arguments: [UUID().uuidString, url.path, data, isFolder])
        }
    }

    // MARK: - Restore access from stored bookmark

    @discardableResult
    func restoreAccess(for url: URL) throws -> URL {
        guard let record = try fetchRecord(for: url) else {
            throw AppError.bookmarkStale(url)
        }

        var isStale = false
        let resolved = try URL(
            resolvingBookmarkData: record.bookmark,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )

        if isStale {
            // Re-create the bookmark with the resolved URL
            try saveBookmark(for: resolved, isFolder: record.isFolder)
        }

        if activeAccess[resolved] != true {
            guard resolved.startAccessingSecurityScopedResource() else {
                throw AppError.bookmarkStale(resolved)
            }
            activeAccess[resolved] = true
        }

        return resolved
    }

    // MARK: - Restore all saved folder bookmarks on launch

    func restoreAllFolders() -> [URL] {
        var restored: [URL] = []
        guard let records = try? fetchAllFolderRecords() else { return [] }

        for record in records {
            let url = URL(fileURLWithPath: record.url)
            if let resolved = try? restoreAccess(for: url) {
                restored.append(resolved)
            }
        }
        return restored
    }

    // MARK: - Stop access

    func stopAccess(for url: URL) {
        if activeAccess[url] == true {
            url.stopAccessingSecurityScopedResource()
            activeAccess[url] = nil
        }
    }

    func stopAllAccess() {
        for (url, isActive) in activeAccess where isActive {
            url.stopAccessingSecurityScopedResource()
        }
        activeAccess.removeAll()
    }

    // MARK: - Remove stored bookmark

    func removeBookmark(for url: URL) throws {
        try db.write { conn in
            try conn.execute(sql: "DELETE FROM bookmarks WHERE url = ?",
                             arguments: [url.path])
        }
        stopAccess(for: url)
    }

    func fetchAllFolderURLs() throws -> [URL] {
        try fetchAllFolderRecords().map { URL(fileURLWithPath: $0.url) }
    }

    // MARK: - Private helpers

    private func fetchRecord(for url: URL) throws -> BookmarkRecord? {
        try db.read { conn in
            try BookmarkRecord.filter(sql: "url = ?", arguments: [url.path]).fetchOne(conn)
        }
    }

    private func fetchAllFolderRecords() throws -> [BookmarkRecord] {
        try db.read { conn in
            try BookmarkRecord.filter(sql: "is_folder = 1").fetchAll(conn)
        }
    }
}
