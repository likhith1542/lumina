import Foundation

// MARK: - SubtitleMemory
//
// Persists the last subtitle file used for each video item.
// Uses security-scoped bookmarks so the sandboxed app can re-access
// the file across launches without re-prompting the user.

enum SubtitleMemory {
    private static let prefix = "subtitle_bookmark_"

    static func save(subtitleURL: URL, forItemId itemId: String) {
        do {
            // Create a security-scoped bookmark so we can reopen the file later
            let bookmark = try subtitleURL.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            UserDefaults.standard.set(bookmark, forKey: prefix + itemId)
        } catch {
            // Sandbox may not support security-scoped bookmarks in all configs —
            // fall back to storing the raw path (works for non-sandboxed builds)
            UserDefaults.standard.set(subtitleURL.path, forKey: prefix + itemId)
        }
    }

    static func load(forItemId itemId: String) -> URL? {
        let key = prefix + itemId

        // Try bookmark first
        if let bookmarkData = UserDefaults.standard.data(forKey: key) {
            var isStale = false
            if let url = try? URL(
                resolvingBookmarkData: bookmarkData,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ) {
                if isStale {
                    // Refresh the bookmark
                    try? save(subtitleURL: url, forItemId: itemId)
                }
                // Verify the file still exists
                guard FileManager.default.fileExists(atPath: url.path) else {
                    clear(forItemId: itemId)
                    return nil
                }
                return url
            }
        }

        // Fall back to raw path
        if let path = UserDefaults.standard.string(forKey: key) {
            let url = URL(fileURLWithPath: path)
            guard FileManager.default.fileExists(atPath: url.path) else {
                clear(forItemId: itemId)
                return nil
            }
            return url
        }

        return nil
    }

    static func clear(forItemId itemId: String) {
        UserDefaults.standard.removeObject(forKey: prefix + itemId)
    }
}
