import Foundation
import AVFoundation

// MARK: - PlayerState

enum PlayerState: Equatable {
    case idle
    case loading(URL)
    case ready               // photo: decoded, video/audio: buffered
    case playing
    case paused
    case finished
    case error(String)

    var isActive: Bool {
        switch self {
        case .playing, .paused: return true
        default: return false
        }
    }

    var canPlay: Bool {
        switch self {
        case .ready, .paused, .finished: return true
        default: return false
        }
    }

    static func == (lhs: PlayerState, rhs: PlayerState) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle),
             (.ready, .ready),
             (.playing, .playing),
             (.paused, .paused),
             (.finished, .finished):         return true
        case (.loading(let a), .loading(let b)): return a == b
        case (.error(let a),   .error(let b)):   return a == b
        default: return false
        }
    }
}

// MARK: - LoopMode

enum LoopMode: String, CaseIterable {
    case none = "none"
    case one  = "one"
    case all  = "all"

    var systemImage: String {
        switch self {
        case .none: return "arrow.right"
        case .one:  return "repeat.1"
        case .all:  return "repeat"
        }
    }
}

// MARK: - PlaybackState

@Observable
final class PlaybackState {
    var currentItem: MediaItem?
    var playerState: PlayerState = .idle
    var position: TimeInterval = 0
    var duration: TimeInterval = 0
    var volume: Float = 1.0
    var playbackSpeed: Float = 1.0
    var loopMode: LoopMode = .none
    var isMuted: Bool = false
    var isShuffle: Bool = false

    // Queue
    var queue: [MediaItem] = []
    var queueIndex: Int = 0

    var progress: Double {
        guard duration > 0 else { return 0 }
        return position / duration
    }

    var currentQueueItem: MediaItem? {
        guard queueIndex >= 0, queueIndex < queue.count else { return nil }
        return queue[queueIndex]
    }

    var hasNext: Bool { queueIndex < queue.count - 1 }
    var hasPrevious: Bool { queueIndex > 0 }

    func loadQueue(_ items: [MediaItem], startAt index: Int = 0) {
        queue = isShuffle ? items.shuffled() : items
        queueIndex = index.clamped(to: 0...(max(0, items.count - 1)))
        currentItem = currentQueueItem
    }
}

// MARK: - AppError

enum AppError: LocalizedError {
    case fileNotFound(URL)
    case unsupportedFormat(String)
    case databaseError(String)
    case bookmarkStale(URL)
    case thumbnailFailed(URL)
    case importFailed(URL, underlying: Error)

    var errorDescription: String? {
        switch self {
        case .fileNotFound(let url):
            return "File not found: \(url.lastPathComponent)"
        case .unsupportedFormat(let ext):
            return "Unsupported format: .\(ext)"
        case .databaseError(let msg):
            return "Database error: \(msg)"
        case .bookmarkStale(let url):
            return "Lost access to: \(url.lastPathComponent). Please re-open the folder."
        case .thumbnailFailed(let url):
            return "Could not generate thumbnail for: \(url.lastPathComponent)"
        case .importFailed(let url, let err):
            return "Import failed for \(url.lastPathComponent): \(err.localizedDescription)"
        }
    }
}

// MARK: - Comparable clamping helper

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
