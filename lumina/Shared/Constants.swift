import Foundation
import CoreMedia

// MARK: - Constants

enum Constants {
    enum UI {
        static let sidebarMinWidth: CGFloat  = 200
        static let sidebarMaxWidth: CGFloat  = 300
        static let inspectorWidth: CGFloat   = 260
        static let thumbnailSize: CGFloat    = 160
        static let thumbnailSpacing: CGFloat = 12
        static let gridColumns: Int          = 4
    }

    enum Playback {
        static let scrubThrottleInterval: TimeInterval = 0.1
        static let timeObserverInterval: Int64         = 1    // 1/600 sec (CMTimeValue)
        static let resumeSaveInterval: TimeInterval    = 5.0
        static let skipInterval: TimeInterval          = 10.0
    }

    enum Cache {
        static let memoryThumbnailLimit: Int   = 200
        static let memoryCostLimit: Int        = 50_000_000  // 50MB
        static let diskCacheName: String       = "thumbnails"
    }

    enum DB {
        static let appSupportFolder: String = "Lumina"
        static let fileName: String         = "lumina.sqlite"
    }

    enum Notification {
        static let libraryDidChange           = Foundation.Notification.Name("LuminaLibraryDidChange")
        static let playbackDidChange          = Foundation.Notification.Name("LuminaPlaybackDidChange")
        static let mediaItemsDeletedExternally = Foundation.Notification.Name("LuminaMediaItemsDeletedExternally")
        static let openExternalFiles           = Foundation.Notification.Name("LuminaOpenExternalFiles")
        static let pausePlayback               = Foundation.Notification.Name("LuminaPausePlayback")
    }
}
