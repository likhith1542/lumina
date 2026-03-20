import AppKit
import AVFoundation
import ImageIO
import CoreMedia

// MARK: - ThumbnailService

/// Three-tier thumbnail cache:
/// 1. NSCache  (in-memory, auto-evicts under memory pressure)
/// 2. Disk     (JPEG in Caches dir, keyed by thumbnailCacheKey)
/// 3. Decode   (background OperationQueue, max 6 concurrent)
final class ThumbnailService: @unchecked Sendable {
    static let shared = ThumbnailService()

    static let thumbnailSize  = CGSize(width: 200, height: 200)
    private static let diskSize = CGSize(width: 400, height: 400)

    private let memoryCache  = ThumbnailMemoryCache()
    private let diskCacheURL: URL
    private let decodeQueue  = OperationQueue()

    private init() {
        let caches = FileManager.default.urls(
            for: .cachesDirectory, in: .userDomainMask
        ).first!
        diskCacheURL = caches.appendingPathComponent(
            "Lumina/thumbnails", isDirectory: true
        )
        try? FileManager.default.createDirectory(
            at: diskCacheURL, withIntermediateDirectories: true
        )
        decodeQueue.maxConcurrentOperationCount = 6
        decodeQueue.qualityOfService = .userInitiated
    }

    // MARK: - Public API

    /// Async — always resolves to an image or nil.
    func thumbnailAsync(for item: MediaItem) async -> NSImage? {
        let key = item.thumbnailCacheKey

        // Tier 1: memory
        if let img = memoryCache.get(key) { return img }

        // Tier 2: disk
        let diskFile = diskCacheURL.appendingPathComponent(key + ".jpg")
        if let data = try? Data(contentsOf: diskFile),
           let img  = NSImage(data: data) {
            memoryCache.set(key, image: img)
            return img
        }

        // Tier 3: decode
        let img: NSImage?
        switch item.mediaType {
        case .photo: img = await decodePhoto(url: item.url)
        case .video: img = await decodeVideoFrame(url: item.url)
        case .audio: img = await decodeAudioArt(url: item.url)
        }

        guard let img else { return nil }

        // Persist to disk cache
        if let jpeg = img.jpegData(compressionFactor: 0.75) {
            try? jpeg.write(to: diskFile)
        }
        memoryCache.set(key, image: img)
        return img
    }

    func evict(key: String) {
        memoryCache.remove(key)
        let file = diskCacheURL.appendingPathComponent(key + ".jpg")
        try? FileManager.default.removeItem(at: file)
    }

    func clearDiskCache() {
        try? FileManager.default.removeItem(at: diskCacheURL)
        try? FileManager.default.createDirectory(
            at: diskCacheURL, withIntermediateDirectories: true
        )
    }

    // MARK: - Photo decode (ImageIO, on background OperationQueue)

    private func decodePhoto(url: URL) async -> NSImage? {
        await withCheckedContinuation { cont in
            decodeQueue.addOperation {
                guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else {
                    cont.resume(returning: nil)
                    return
                }
                let options: [CFString: Any] = [
                    kCGImageSourceThumbnailMaxPixelSize:          400,
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform:   true,
                    kCGImageSourceShouldCacheImmediately:         false
                ]
                guard let cg = CGImageSourceCreateThumbnailAtIndex(
                    src, 0, options as CFDictionary
                ) else {
                    cont.resume(returning: nil)
                    return
                }
                cont.resume(returning: NSImage(cgImage: cg, size: Self.thumbnailSize))
            }
        }
    }

    // MARK: - Video frame decode (AVFoundation + FFmpeg fallback)

    private func decodeVideoFrame(url: URL) async -> NSImage? {
        let ext = url.pathExtension.lowercased()

        // For unsupported formats, use ffmpeg to extract a frame
        if FFmpegBridge.unsupportedExtensions.contains(ext) {
            if let img = await decodeVideoFrameFFmpeg(url: url) { return img }
        }

        // Native AVFoundation path
        let asset = AVURLAsset(url: url)
        let gen   = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = Self.diskSize

        var sampleTime = CMTime(seconds: 1, preferredTimescale: 600)
        if let rawDuration = try? await asset.load(.duration) {
            let secs = CMTimeGetSeconds(rawDuration)
            if secs.isFinite && secs > 0 {
                sampleTime = CMTime(seconds: max(secs * 0.1, 1), preferredTimescale: 600)
            }
        }

        guard let cg = try? await gen.image(at: sampleTime).image else { return nil }
        return NSImage(cgImage: cg, size: Self.thumbnailSize)
    }

    private func decodeVideoFrameFFmpeg(url: URL) async -> NSImage? {
        guard let ffmpeg = FFmpegBridge.shared.ffmpegPathSync else { return nil }

        let thumbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("lumina_thumb_\(url.lastPathComponent.hash).jpg")
        defer { try? FileManager.default.removeItem(at: thumbURL) }

        return await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: ffmpeg)
            process.arguments = [
                "-ss", "00:01:00",          // seek to 1 min (avoids black opening frames)
                "-i", url.path,
                "-vframes", "1",            // extract one frame
                "-vf", "scale=400:-1",      // scale to 400px wide
                "-q:v", "3",               // JPEG quality
                "-y", thumbURL.path
            ]
            process.standardError  = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice

            process.terminationHandler = { proc in
                if proc.terminationStatus == 0,
                   let data  = try? Data(contentsOf: thumbURL),
                   let image = NSImage(data: data) {
                    continuation.resume(returning: image)
                } else {
                    // Retry at 5 seconds if 1 min seek failed (short file)
                    self.decodeVideoFrameFFmpegAt(ffmpeg: ffmpeg, url: url,
                                                  seconds: 5, continuation: continuation)
                }
            }

            try? process.run()
        }
    }

    private func decodeVideoFrameFFmpegAt(ffmpeg: String, url: URL,
                                          seconds: Int,
                                          continuation: CheckedContinuation<NSImage?, Never>) {
        let thumbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("lumina_thumb2_\(url.lastPathComponent.hash).jpg")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpeg)
        process.arguments = [
            "-ss", "\(seconds)",
            "-i", url.path,
            "-vframes", "1",
            "-vf", "scale=400:-1",
            "-q:v", "3",
            "-y", thumbURL.path
        ]
        process.standardError  = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice

        process.terminationHandler = { proc in
            if proc.terminationStatus == 0,
               let data  = try? Data(contentsOf: thumbURL),
               let image = NSImage(data: data) {
                try? FileManager.default.removeItem(at: thumbURL)
                continuation.resume(returning: image)
            } else {
                try? FileManager.default.removeItem(at: thumbURL)
                continuation.resume(returning: nil)
            }
        }

        try? process.run()
    }

    // MARK: - Audio art decode (embedded metadata)

    private func decodeAudioArt(url: URL) async -> NSImage? {
        let asset = AVURLAsset(url: url)
        guard let meta = try? await asset.load(.metadata) else { return nil }
        for item in meta {
            guard item.commonKey == .commonKeyArtwork else { continue }
            if let data = try? await item.load(.dataValue),
               let img  = NSImage(data: data) {
                return img
            }
        }
        return nil
    }
}

// MARK: - ThumbnailMemoryCache

private final class ThumbnailMemoryCache: @unchecked Sendable {
    private let cache = NSCache<NSString, NSImage>()

    init() {
        cache.countLimit      = 200
        cache.totalCostLimit  = 50_000_000  // ~50 MB
    }

    func get(_ key: String) -> NSImage? {
        cache.object(forKey: key as NSString)
    }

    func set(_ key: String, image: NSImage) {
        let cost = Int(image.size.width * image.size.height * 4)
        cache.setObject(image, forKey: key as NSString, cost: cost)
    }

    func remove(_ key: String) {
        cache.removeObject(forKey: key as NSString)
    }
}
